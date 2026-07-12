import DOMPurify from 'dompurify';
import * as css from 'css-tree';
import {Resource} from '@readium/shared';
const htmlTypes=new Set(['application/xhtml+xml','text/html']);
const assetTypes=new Set(['image/png','image/jpeg','image/gif','image/webp','font/woff','font/woff2','font/ttf','font/otf','application/font-woff','application/vnd.ms-opentype','application/font-sfnt','application/x-font-ttf']);
export class PublicationResources {
 constructor(resources){
  this.map=new Map();this.urls=new Map();this.active=new Set();this.warnings=new Set();
  let size=0;
  for(const item of resources){
   if(typeof item.href!=='string'||/[:\\?#%\x00-\x1f]/.test(item.href)||item.href.split('/').some(x=>!x||x==='.'||x==='..')||this.map.has(item.href))throw Error('Invalid resource identity');
   const bytes=Uint8Array.from(atob(item.dataBase64),c=>c.charCodeAt(0));size+=bytes.length;
   if(size>256*1024*1024)throw Error('Publication exceeds reader memory budget');
   this.map.set(item.href,{...item,bytes});
  }
 }
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
  if(this.active.has(href))throw Error('Cyclic CSS import');
  this.active.add(href);
  try{
   let body=item.bytes;
   if(item.type==='text/css')body=this.styles(new TextDecoder().decode(body),href);
   else if(!assetTypes.has(item.type))throw Error('Unsupported asset: '+item.type);
   const url=URL.createObjectURL(new Blob([body],{type:item.type}));this.urls.set(href,url);return url+fragment;
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
 chapter(href){
  const item=this.map.get(href);if(!item||!htmlTypes.has(item.type))throw Error('Only HTML EPUB chapters are supported in this build');
  const clean=DOMPurify.sanitize(new TextDecoder().decode(item.bytes),{WHOLE_DOCUMENT:true,USE_PROFILES:{html:true},ADD_TAGS:['link'],ADD_ATTR:['rel'],FORBID_TAGS:['script','base','meta','iframe','object','embed','form','input','button','textarea','select'],FORBID_ATTR:['srcset','ping','target']});
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
      try{el.setAttribute(attr.name,this.asset(href,attr.value))}catch(error){el.removeAttribute(attr.name);this.warnings.add(error.message)}
     }
    }
   }
   if(el.tagName==='STYLE')el.textContent=this.styles(el.textContent,href);
   if(el.tagName==='LINK'&&el.getAttribute('rel')!=='stylesheet')el.remove();
  }
  const flow=doc.createElement('style');flow.textContent=':where(h1,h2,h3,h4,h5,h6){break-after:avoid;page-break-after:avoid;}';doc.head.insertBefore(flow,doc.head.firstChild);
  return '<!doctype html>'+doc.documentElement.outerHTML;
 }
 close(){for(const url of this.urls.values())URL.revokeObjectURL(url);this.urls.clear();}
}
class ChapterResource extends Resource{
 constructor(link,pool){super();this.item=link;this.pool=pool}
 async link(){return this.item} async length(){return (await this.read()).length}
 async read(range){const bytes=new TextEncoder().encode(this.pool.chapter(this.item.href));return range?bytes.slice(range.start,range.endInclusive+1):bytes}
 close(){}
}
export class PublicationFetcher{
 constructor(pool){this.pool=pool}links(){return []}get(link){return new ChapterResource(link,this.pool)}close(){}
}
