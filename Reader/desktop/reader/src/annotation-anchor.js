// Match ReaderStateValidation's UTF-16 locator-text contract. A shortened quote
// is a preview, never a replacement anchor for a longer selected passage.
export const MAX_LOCATOR_TEXT=16384;
export function quotePreview(value){
 const text=String(value??'');let end=Math.min(text.length,MAX_LOCATOR_TEXT);
 if(end<text.length&&end>0&&/[\uD800-\uDBFF]/.test(text[end-1]))end--;
 return text.slice(0,end);
}
export function annotationLocator(value){
 if(!value)throw Error('Select a passage to annotate.');
 const locator=JSON.parse(JSON.stringify(value));
 if(Object.values(locator.text??{}).some(text=>typeof text==='string'&&text.length>MAX_LOCATOR_TEXT)){
  const range=locator.locations?.domRange;
  if(!range?.start?.cssSelector||!range?.end?.cssSelector)throw Error('This long passage needs a complete selection anchor. Select it again.');
  delete locator.text;
  // Keep the full endpoints and navigation progression, without fallbacks that
  // would resolve to a prefix or an entire containing element if endpoints fail.
  delete locator.locations.cssSelector;delete locator.locations.fragments;
 }
 return locator;
}
