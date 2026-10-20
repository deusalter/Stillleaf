// Whole-book screen counts before every chapter has been laid out. The footer shows these at once; the background
// counter replaces them with exact counts. They are display-only: native progress, page evidence and goals use
// chapter-local screens and text offsets, never these numbers.

// An illustration takes part of a screen and often pushes text to the next one.
const IMAGE_SCREENS=.6;
// Fewer measured screens than this say too little about a new type size to rescale another layout by.
const MIN_REFERENCE_SCREENS=6;
const MAX_KEY=8192,MAX_COUNT=1_000_000,MAX_MAPS=16;
const known=value=>Number.isSafeInteger(value)&&value>0;

/**
 * Per-chapter screen counts for one layout. `exact` holds measured counts (null where unknown); `provisional` holds counts
 * that are measured but not settled (a chapter still loading, or one being measured again). `references` are complete
 * exact maps of other layouts of this book, most recent first. `weights` are per-chapter {text, images}. Returns
 * {counts, exact, sample}, where `sample` is the measured screens an estimate rests on, or null when nothing measured
 * can calibrate an estimate.
 */
export function estimateCounts({exact:settled,provisional=[],references=[],weights=null,density=null}){
 if(settled.length&&settled.every(known))return {counts:settled.slice(),exact:true};
 const exact=settled.map((count,index)=>known(count)?count:known(provisional[index])?provisional[index]:null);
 if(exact.every(known))return {counts:exact,exact:false,sample:exact.reduce((a,b)=>a+b,0)};
 const measured=exact.flatMap((count,index)=>known(count)?[index]:[]);
 // Another layout keeps each chapter's own shape (illustrations, verse, short scenes); only the scale changes.
 // Each count carries on average half a screen of rounding, which a new layout does not scale.
 for(const reference of references){
  if(reference?.length!==exact.length)continue;
  let now=0,then=0;for(const index of measured){now+=exact[index];then+=reference[index]}
  if(then<MIN_REFERENCE_SCREENS)continue;
  const ratio=(now-measured.length/2)/(then-measured.length/2);
  return {counts:exact.map((count,index)=>known(count)?count:Math.max(1,Math.ceil((reference[index]-.5)*ratio))),exact:false,sample:now};
 }
 if(weights?.length!==exact.length)return null;
 let screens=0,text=0;
 // A one-screen chapter (title page, epigraph) holds any amount of text up to a screen, so it calibrates nothing.
 for(const index of measured){const weight=weights[index];if(!(weight?.text>0)||exact[index]<2)continue;screens+=exact[index]-.5-IMAGE_SCREENS*(weight.images??0);text+=weight.text}
 // `density` (screens per character, or a function giving it) covers a book whose measured chapters hold no text.
 const perCharacter=text>0&&screens>0?screens/text:typeof density==='function'?density():density;
 if(!(perCharacter>0))return null;
 return {counts:exact.map((count,index)=>known(count)?count:Math.max(1,Math.ceil(perCharacter*(weights[index]?.text??0)+IMAGE_SCREENS*(weights[index]?.images??0)))),exact:false,sample:text>0?screens:0};
}

/** Page maps the host saved for this book: well-formed, matching its chapter count, bounded. */
export function pageMapsFor(value,length){
 if(!Array.isArray(value))return [];
 const seen=new Set();
 return value.filter(map=>map&&typeof map.key==='string'&&map.key.length<=MAX_KEY&&!seen.has(map.key)&&Array.isArray(map.counts)&&map.counts.length===length&&map.counts.every(count=>known(count)&&count<=MAX_COUNT)&&seen.add(map.key))
  .slice(0,MAX_MAPS).map(map=>({key:map.key,counts:map.counts.slice()}));
}

const pageOf=(counts,chapter,local)=>counts.slice(0,chapter).reduce((a,b)=>a+b,0)+Math.max(1,Math.min(local.first,counts[chapter]));
const sameCounts=(a,b)=>a.length===b.length&&a.every((value,index)=>value===b[index]);

/**
 * The whole-book page shown in the footer. A new layout's count appears once it is exact or its estimate rests on
 * `enough` measured screens, and otherwise after a short hold: `hold` when a book opens, `changeHold` when the footer
 * already shows a page it can keep meanwhile. A move by the reader ends the hold, since the kept page is then stale. After that a better count is adopted only together with a move the reader
 * made and in its direction, so the number never ticks on its own and a forward turn never shows a lower page.
 * `show` returns {hold: ms} while holding, and null when there is nothing to show.
 */
export class StablePageCount{
 constructor({hold=300,changeHold=hold,enough=Infinity,now=()=>performance.now()}={}){this.hold=hold;this.changeHold=changeHold;this.enough=enough;this.now=now;this.reset()}
 reset(){this.key=null;this.counts=null;this.exact=false;this.page=undefined;this.place=null;this.shown=false}
 show({key,best,chapter,local}){
  if(!local||chapter<0)return null;
  const time=this.now(),usable=best&&best.counts.length>chapter,adopt=()=>{this.counts=best.counts.slice();this.exact=best.exact;this.shown=true};
  if(this.key!==key||(usable&&this.counts&&this.counts.length!==best.counts.length)){this.key=key;this.since=time;this.limit=this.shown?this.changeHold:this.hold;this.counts=null;this.page=undefined;this.place=null;this.held=null}
  if(!this.counts){
   if(!usable)return null;
   const place=chapter+':'+local.first;this.held??=place;
   if(!best.exact&&!(best.sample>=this.enough)&&time-this.since<this.limit&&place===this.held)return {hold:this.limit-(time-this.since)};
   adopt();
  }else if(usable&&(this.exact!==best.exact||!sameCounts(this.counts,best.counts))){
   // The reader's own direction, from the place itself: a stale count may hide a move within its chapter.
   const moved=this.place?Math.sign(chapter-this.place.chapter||local.first-this.place.first):0,next=pageOf(best.counts,chapter,local)-(this.page??NaN);
   if(sameCounts(this.counts,best.counts)||(moved!==0&&Math.sign(next)===moved))adopt();
  }
  if(this.counts.length<=chapter)return null;
  const page=pageOf(this.counts,chapter,local);this.page=page;this.place={chapter,first:local.first};
  return {first:page,last:page,total:this.counts.reduce((a,b)=>a+b,0),exact:this.exact};
 }
}
