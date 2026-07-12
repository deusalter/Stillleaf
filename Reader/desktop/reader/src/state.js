export const DEFAULT_PREFERENCES=Object.freeze({theme:'system',fontFamily:'publisher',fontSize:1.2,lineHeight:1.6,measure:65,scroll:false,fontWeight:null,textAlign:'publisher',hyphens:null,letterSpacing:0,wordSpacing:0,columns:'one'});
const clamp=(value,min,max,fallback)=>Number.isFinite(value)?Math.min(max,Math.max(min,value)):fallback;
export function preferences(value={}){return {theme:['system','paper','sepia','dark'].includes(value.theme)?value.theme:'system',fontFamily:['publisher','serif','sans'].includes(value.fontFamily)?value.fontFamily:'publisher',fontSize:clamp(value.fontSize,.5,3,1.2),lineHeight:clamp(value.lineHeight,1,3,1.6),measure:clamp(value.measure,20,120,65),scroll:value.scroll===true,fontWeight:value.fontWeight==null?null:clamp(value.fontWeight,100,1000,400),textAlign:['publisher','start','justify'].includes(value.textAlign)?value.textAlign:'publisher',hyphens:typeof value.hyphens==='boolean'?value.hyphens:null,letterSpacing:clamp(value.letterSpacing,0,1,0),wordSpacing:clamp(value.wordSpacing,0,1,0),columns:value.columns==='two'?'two':'one'}}
export function restoreState(value,editionId,validLocator){
 const state={schemaVersion:1,editionId,revision:0,position:null,preferences:preferences(),bookmarks:[],annotations:[]};
 if(!value)return state;
 if(value.schemaVersion!==1||value.editionId!==editionId)throw Error('Incompatible saved reading data; it has not been overwritten.');
 state.revision=Number.isSafeInteger(value.revision)&&value.revision>=0?value.revision:0;
 state.position=validLocator(value.position);if(value.position&&!state.position)throw Error('Unknown saved position; it has not been overwritten.');state.preferences=preferences(value.preferences);
 const checkedText=(value,max)=>{if(typeof value!=='string'||value.length>max)throw Error('Saved reading data exceeds supported limits; it has not been overwritten.');return value};
 const date=value=>{checkedText(value,64);if(!Number.isFinite(Date.parse(value)))throw Error('Invalid saved timestamp; reading data has not been overwritten.');return value};
 const items=value=>{if(!Array.isArray(value)||value.length>2000)throw Error('Invalid saved collection; reading data has not been overwritten.');return value};
 const locator=value=>{const result=validLocator(value);if(!result)throw Error('Unknown saved location; reading data has not been overwritten.');return result};
 for(const item of items(value.bookmarks??[])){
  state.bookmarks.push({id:checkedText(item.id,128),locator:locator(item.locator),label:checkedText(item.label,4096),createdAt:date(item.createdAt)});
 }
 for(const item of items(value.annotations??[])){
  state.annotations.push({id:checkedText(item.id,128),locator:locator(item.locator),quote:checkedText(item.quote,32768),note:checkedText(item.note,65536),color:checkedText(item.color,64),createdAt:date(item.createdAt),updatedAt:date(item.updatedAt)});
 }
 return state;
}
export function selectorFor(element){
 if(element.id)return '#'+CSS.escape(element.id);
 const parts=[];let cursor=element;
 while(cursor&&cursor.localName!=='html'){
  const siblings=[...cursor.parentElement.children].filter(x=>x.localName===cursor.localName);
  parts.unshift(cursor.localName+':nth-of-type('+(siblings.indexOf(cursor)+1)+')');cursor=cursor.parentElement;
 }
 return parts.join(' > ');
}
export function rangePoint(node,offset){
 if(node.nodeType===Node.TEXT_NODE)return {cssSelector:selectorFor(node.parentElement),textNodeIndex:[...node.parentElement.childNodes].indexOf(node),charOffset:offset};
 return {cssSelector:selectorFor(node),textNodeIndex:offset};
}
