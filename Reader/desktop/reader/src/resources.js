import DOMPurify from 'dompurify';
import * as css from 'css-tree';
import {Resource} from '@readium/shared';
const htmlTypes=new Set(['application/xhtml+xml','text/html']);
const assetTypes=new Set(['image/png','image/jpeg','image/gif','image/webp','font/woff','font/woff2','font/ttf','font/otf','font/sfnt','font/opentype','font/truetype','application/font-woff','application/vnd.ms-opentype','application/font-sfnt','application/x-font-ttf','application/x-font-otf','application/x-font-opentype','application/x-font-truetype','application/x-font-woff','application/font-ttf','application/font-otf']);
const XLINK='http://www.w3.org/1999/xlink';
/** Calibre-style covers wrap a single raster in `<svg><image/></svg>`. The HTML-only sanitizer
 *  drops SVG, which left a blank first page, so turn that wrapper into a plain `<img>`. */
export function unwrapSvgImages(source){
 if(!/<svg[\s>]/iu.test(source)||!/<image[\s>]/iu.test(source))return source;
 const doc=new DOMParser().parseFromString(source,'text/html');let changed=false;
 for(const svg of [...doc.querySelectorAll('svg')]){
  const images=svg.querySelectorAll('image');
  if(images.length!==1||svg.querySelector('text,path,rect,circle,ellipse,line,polyline,polygon,use,foreignObject'))continue;
  const image=images[0],src=image.getAttribute('href')||image.getAttributeNS(XLINK,'href')||image.getAttribute('xlink:href');if(!src)continue;
  const img=doc.createElement('img');img.setAttribute('src',src);
  img.setAttribute('alt',svg.getAttribute('aria-label')||image.getAttribute('alt')||'');
  img.setAttribute('style','display:block;max-width:100%;max-height:100vh;height:auto;margin:0 auto;object-fit:contain');
  svg.replaceWith(img);changed=true;
 }
 return changed?'<!DOCTYPE html>'+doc.documentElement.outerHTML:source;
}
const MAX_RESOURCE_BYTES=32*1024*1024,MAX_PUBLICATION_BYTES=256*1024*1024,CHAPTER_CACHE=12,MAX_PRELOAD_ROUNDS=8;
export class PublicationResources {
 /** Resources are either eager (`dataBase64`) or host-served (`url` plus declared `size`).
  *  Host-served bytes are fetched on first use, so opening a book never copies the whole publication. */
 constructor(resources,{fetch:load=globalThis.fetch?.bind(globalThis)}={}){
  this.map=new Map();this.urls=new Map();this.active=new Set();this.warnings=new Set();this.chapters=new Map();this.loading=new Map();this.load=load;this.pending=null;
  let size=0;
  for(const item of resources){
   if(typeof item.href!=='string'||/[:\\?#%\x00-\x1f]/.test(item.href)||item.href.split('/').some(x=>!x||x==='.'||x==='..')||this.map.has(item.href))throw Error('Invalid resource identity');
   if(typeof item.dataBase64==='string'){
    const bytes=Uint8Array.from(atob(item.dataBase64),c=>c.charCodeAt(0));size+=bytes.length;
    this.map.set(item.href,{href:item.href,type:item.type,size:bytes.length,bytes});
   }else{
    if(typeof item.url!=='string'||!Number.isSafeInteger(item.size)||item.size<0||item.size>MAX_RESOURCE_BYTES)throw Error('Invalid resource identity');
    size+=item.size;this.map.set(item.href,{href:item.href,type:item.type,size:item.size,url:item.url,bytes:null});
   }
   if(size>MAX_PUBLICATION_BYTES)throw Error('Publication exceeds reader memory budget');
  }
 }
 size(href){return this.map.get(href)?.size??0}
 /** Loads one resource's bytes once; concurrent callers share the request. */
 async read(href){
  const item=this.map.get(href);if(!item)throw Error('Missing local resource: '+href);
  if(item.bytes)return item.bytes;
  if(!this.loading.has(href))this.loading.set(href,(async()=>{
   if(!this.load)throw Error('This reader cannot load book resources.');
   const response=await this.load(item.url,{cache:'no-store',credentials:'omit',redirect:'error'});
   if(!response.ok&&response.status!==0)throw Error('Missing local resource: '+href);
   const bytes=new Uint8Array(await response.arrayBuffer());
   if(bytes.length!==item.size)throw Error('Book resource changed on disk: '+href);
   return bytes;
  })().finally(()=>this.loading.delete(href)));
  const bytes=await this.loading.get(href);
  if(this.map.get(href)===item&&!item.bytes)item.bytes=bytes;
  return bytes;
 }
 /** Frees fetched bytes once a blob URL or sanitized chapter holds the content. */
 release(item){if(item.url)item.bytes=null}
 resolve(base,reference){
  if(!reference || /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(reference))throw Error('External resource blocked');
  const url=new URL(reference,'https://publication.invalid/'+base);
  if(url.origin!=='https://publication.invalid'||url.search)throw Error('External resource blocked');
  const href=decodeURIComponent(url.pathname.slice(1));
  if(!this.map.has(href))throw Error('Missing local resource: '+href);
  return {href,fragment:url.hash};
 }
 asset(base,ref){
  const {href,fragment}=this.resolve(base,ref);
  if(this.urls.has(href))return this.urls.get(href)+fragment;
  const item=this.map.get(href);
  if(item.type!=='text/css'&&!assetTypes.has(item.type.toLowerCase()))throw Error('Unsupported asset: '+item.type);
  if(!item.bytes){
   // First pass of chapter(): record what to fetch, keep rewriting.
   if(this.pending){this.pending.add(href);return 'about:blank'}
   throw Error('Missing local resource: '+href);
  }
  if(this.active.has(href))throw Error('Cyclic CSS import');
  this.active.add(href);
  const waiting=this.pending?.size??0;
  try{
   let body=item.bytes;
   if(item.type==='text/css')body=this.styles(new TextDecoder().decode(body),href);
   // A stylesheet whose own imports are still loading must be regenerated later.
   if(this.pending&&this.pending.size>waiting)return 'about:blank';
   const url=URL.createObjectURL(new Blob([body],{type:item.type}));this.urls.set(href,url);this.release(item);return url+fragment;
  }finally{this.active.delete(href)}
 }
 styles(source,base,inline=false){
  try{
   const ast=css.parse(source,{context:inline?'declarationList':'stylesheet'});
   css.walk(ast,node=>{
    if(node.type==='Raw')throw Error('Unsupported CSS syntax');
    if(node.type==='Url')node.value=this.asset(base,node.value);
    if(node.type==='Function'&&['image-set','-webkit-image-set','expression'].includes(node.name.toLowerCase()))throw Error('Unsupported CSS image/expression syntax');
    if(node.type==='Atrule'&&node.name.toLowerCase()==='import'){
     const first=node.prelude?.children?.first;
     if(first?.type==='String')first.value=this.asset(base,first.value);
    }
   });return css.generate(ast);
  }catch(error){this.warnings.add('Some publisher styling was unavailable: '+error.message);return '';}
 }
 /** Sanitized chapter HTML. Referenced images, fonts and stylesheets are fetched
  *  before the final rewrite, which then runs synchronously as before. */
 async chapter(href){
  const item=this.map.get(href);if(!item||!htmlTypes.has(item.type))throw Error('Only HTML EPUB chapters are supported in this build');
  if(this.chapters.has(href)){const html=this.chapters.get(href);this.chapters.delete(href);this.chapters.set(href,html);return html}
  const source=unwrapSvgImages(new TextDecoder().decode(await this.read(href)));
  let html=null;
  for(let round=0;round<MAX_PRELOAD_ROUNDS&&html===null;round++){
   let needed,result;this.pending=new Set();
   try{result=this.rewrite(source,href,true)}finally{needed=[...this.pending];this.pending=null}
   // Nothing left to fetch: this pass already produced the final document.
   if(!needed.length){for(const warning of result.warnings)this.warnings.add(warning);html=result.html;break}
   await Promise.all(needed.map(ref=>this.read(ref).catch(error=>this.warnings.add(error.message))));
  }
  html??=this.rewrite(source,href,false).html;
  this.release(item);this.chapters.set(href,html);
  while(this.chapters.size>CHAPTER_CACHE)this.chapters.delete(this.chapters.keys().next().value);
  return html;
 }
 rewrite(source,href,collecting){
  const warnings=collecting?new Set():this.warnings;
  const clean=DOMPurify.sanitize(source,{WHOLE_DOCUMENT:true,USE_PROFILES:{html:true},ADD_TAGS:['link'],ADD_ATTR:['rel'],FORBID_TAGS:['script','base','meta','iframe','object','embed','form','input','button','textarea','select'],FORBID_ATTR:['srcset','ping','target']});
  const doc=new DOMParser().parseFromString(clean,'text/html');
  for(const el of doc.querySelectorAll('*')){
   for(const attr of [...el.attributes]){
    if(attr.name.startsWith('on'))el.removeAttribute(attr.name);
    if(attr.name==='style')el.setAttribute('style',this.styles(attr.value,href,true));
    if(['src','href','poster','background','action'].includes(attr.name)){
     if(el.tagName==='A'&&attr.name==='href'){
      // Preserve internal links in resource space for Readium navigation.
      try{this.resolve(href,attr.value);el.setAttribute('href',new URL(attr.value,'https://publication.invalid/'+href).pathname.slice(1)+new URL(attr.value,'https://publication.invalid/'+href).hash)}catch{el.removeAttribute(attr.name)}
     }else{
      try{el.setAttribute(attr.name,this.asset(href,attr.value))}catch(error){el.removeAttribute(attr.name);warnings.add(error.message)}
     }
    }
   }
   if(el.tagName==='STYLE')el.textContent=this.styles(el.textContent,href);
   if(el.tagName==='LINK'&&el.getAttribute('rel')!=='stylesheet')el.remove();
  }
  const flow=doc.createElement('style');flow.textContent=':where(h1,h2,h3,h4,h5,h6){break-after:avoid;page-break-after:avoid;}';doc.head.insertBefore(flow,doc.head.firstChild);
  return {html:'<!doctype html>'+doc.documentElement.outerHTML,warnings};
 }
 close(){for(const url of this.urls.values())URL.revokeObjectURL(url);this.urls.clear();this.chapters.clear();}
}
class ChapterResource extends Resource{
 constructor(link,pool){super();this.item=link;this.pool=pool}
 async link(){return this.item} async length(){return (await this.read()).length}
 async read(range){const bytes=new TextEncoder().encode(await this.pool.chapter(this.item.href));return range?bytes.slice(range.start,range.endInclusive+1):bytes}
 close(){}
}
export class PublicationFetcher{
 constructor(pool){this.pool=pool}links(){return []}get(link){return new ChapterResource(link,this.pool)}close(){}
}
