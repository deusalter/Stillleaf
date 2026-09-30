import {FONTS} from './appearance';

const luminance=hex=>{const values=hex.slice(1).match(/../g).map(x=>parseInt(x,16)/255).map(x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4);return .2126*values[0]+.7152*values[1]+.0722*values[2]};
export function contrast(a,b){const x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05)}
const loaders={literata:()=>import('./font-assets/literata'), 'source-serif':()=>import('./font-assets/source-serif'),lora:()=>import('./font-assets/lora'),'libre-baskerville':()=>import('./font-assets/libre-baskerville'),atkinson:()=>import('./font-assets/atkinson'),inter:()=>import('./font-assets/inter'),nunito:()=>import('./font-assets/nunito'),'source-sans':()=>import('./font-assets/source-sans')};
const cache=new Map(),styles=new WeakMap();
export async function fontCSS(id){
 if(!loaders[id])return '';
 if(!cache.has(id))cache.set(id,loaders[id]().then(({default:faces})=>faces.map(face=>`@font-face{font-family:"Stillleaf ${FONTS.find(font=>font.id===id).label}";src:url("${face.url}") format("woff2");font-style:${face.style};font-weight:${face.weight};font-display:swap}`).join('\n')));
 return cache.get(id);
}
export async function installFont(doc,id,css){
 // Readium can expose a document while replacing/unloading its frame. Its
 // eventual chapter receives trustedFontCSS through the resource sanitizer.
 if(!doc?.head)return;
 let style=styles.get(doc);if(!style){style=doc.createElement('style');doc.head.append(style);styles.set(doc,style)}
 style.textContent=css;
 const font=FONTS.find(font=>font.id===id);
 if(loaders[id]&&doc.fonts)await Promise.all([doc.fonts.load(`400 18px "Stillleaf ${font.label}"`),doc.fonts.load(`italic 400 18px "Stillleaf ${font.label}"`)]);
}
