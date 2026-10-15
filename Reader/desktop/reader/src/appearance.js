// Reading appearance: page themes, typefaces and margins. Stored ids are part of
// the saved-state contract (hosts validate them), so ids never change once shipped;
// labels can. `paper`, `sepia`, `dark`, `serif` and `sans` predate this table.

/** Page colours. `chrome` tones the reader bar and panels around the page. */
export const THEMES=Object.freeze([
 {id:'original',label:'Original',scheme:'light',background:'#FFFFFF',text:'#111113',link:'#0A57AD',selection:'#B4D5FE',chrome:'#F2F2F4',muted:'#505055',panel:'#FAFAFB'},
 {id:'paper',label:'Stillleaf',scheme:'light',background:'#F0F7F3',text:'#0E2C24',link:'#066B56',selection:'#B9DCCE',chrome:'#DFECE7',muted:'#43605A',panel:'#F6FAF7'},
 {id:'sepia',label:'Warm',scheme:'light',background:'#F6F1E3',text:'#28241A',link:'#6A4C18',selection:'#E3D5A8',chrome:'#E7E5D8',muted:'#5C5543',panel:'#FBF7EC'},
 {id:'calm',label:'Calm',scheme:'light',background:'#EEE2CC',text:'#261E15',link:'#6E4420',selection:'#D8C39D',chrome:'#E2D4BA',muted:'#5B4C3B',panel:'#F4EBDA'},
 {id:'focus',label:'Focus',scheme:'light',background:'#FFFBEF',text:'#100F0C',link:'#5C430E',selection:'#F1E2B6',chrome:'#F3EDDC',muted:'#524E45',panel:'#FFFDF6'},
 {id:'quiet',label:'Quiet',scheme:'dark',background:'#3A3A3E',text:'#F2F2F4',link:'#C6DAF4',selection:'#5E5E66',chrome:'#2F2F33',muted:'#C4C4CA',panel:'#424247'},
 {id:'dark',label:'Dark',scheme:'dark',background:'#14231F',text:'#F3FAF5',link:'#7FE3BD',selection:'#3F5E50',chrome:'#0D1916',muted:'#B9D2C7',panel:'#1A2C28'},
 // Night is true black for dark rooms and OLED screens: bright, slightly warm text, and dimmed illustrations.
 {id:'night',label:'Night',scheme:'dark',background:'#000000',text:'#ECECEE',link:'#A3C4F0',selection:'#2E2E34',chrome:'#000000',muted:'#A2A2A8',panel:'#111113',dimImages:true},
 {id:'white',label:'White',scheme:'light',background:'#FFFFFF',text:'#121416',link:'#225EAD',selection:'#B9DCCE',chrome:'#FFFFFF',muted:'#121416',panel:'#FFFFFF'},
 {id:'stone',label:'Stone',scheme:'light',background:'#E9E8E4',text:'#1C1D1C',link:'#3D514B',selection:'#B9DCCE',chrome:'#E9E8E4',muted:'#1C1D1C',panel:'#E9E8E4'},
 {id:'mist',label:'Mist',scheme:'light',background:'#EAF1F7',text:'#14273A',link:'#2C5D82',selection:'#B9DCCE',chrome:'#EAF1F7',muted:'#14273A',panel:'#EAF1F7'},
 {id:'forest',label:'Forest',scheme:'light',background:'#E4EFE6',text:'#123322',link:'#1F5639',selection:'#B9DCCE',chrome:'#E4EFE6',muted:'#123322',panel:'#E4EFE6'},
 {id:'dusk',label:'Dusk',scheme:'dark',background:'#25212E',text:'#F7F1FA',link:'#E0C4F2',selection:'#466858',chrome:'#25212E',muted:'#F7F1FA',panel:'#25212E'},
 {id:'midnight',label:'Midnight',scheme:'dark',background:'#0A0E15',text:'#EAEFF7',link:'#A8C9F6',selection:'#466858',chrome:'#0A0E15',muted:'#EAEFF7',panel:'#0A0E15'},
 {id:'custom',label:'Custom',scheme:'light',background:'#F0F7F3',text:'#183D33',link:'#087D65',selection:'#B9DCCE',chrome:'#F0F7F3',muted:'#183D33',panel:'#F0F7F3'}
]);
export const THEME_IDS=Object.freeze(['system',...THEMES.map(t=>t.id)]);
/** `system` follows the Mac: Stillleaf by day, true-black Night in dark mode. */
export function resolveTheme(id,prefersDark){
 const chosen=id==='system'?(prefersDark?'night':'paper'):id;
 return THEMES.find(t=>t.id===chosen)??THEMES.find(t=>t.id==='paper');
}

/** `probe` names the installed family used to decide whether to offer a typeface. */
export const FONTS=Object.freeze([
 {id:'publisher',label:'Original',stack:null},
 {id:'newyork',label:'New York',stack:'ui-serif, "New York", Georgia, serif',probe:'ui-serif'},
 {id:'sans',label:'San Francisco',stack:'system-ui, -apple-system, sans-serif'},
 {id:'athelas',label:'Athelas',stack:'Athelas, Georgia, serif',probe:'Athelas'},
 {id:'charter',label:'Charter',stack:'Charter, "Bitstream Charter", Georgia, serif',probe:'Charter'},
 {id:'serif',label:'Georgia',stack:'Georgia, "Times New Roman", serif',probe:'Georgia'},
 {id:'iowan',label:'Iowan',stack:'"Iowan Old Style", Palatino, serif',probe:'Iowan Old Style'},
 {id:'palatino',label:'Palatino',stack:'Palatino, "Palatino Linotype", "Book Antiqua", serif',probe:'Palatino'},
 {id:'seravek',label:'Seravek',stack:'Seravek, "Gill Sans", system-ui, sans-serif',probe:'Seravek'},
 {id:'times',label:'Times New Roman',stack:'"Times New Roman", Times, serif',probe:'Times New Roman'},
 {id:'literata',label:'Literata',stack:'"Stillleaf Literata", serif'},
 {id:'source-serif',label:'Source Serif 4',stack:'"Stillleaf Source Serif 4", serif'},
 {id:'lora',label:'Lora',stack:'"Stillleaf Lora", serif'},
 {id:'libre-baskerville',label:'Libre Baskerville',stack:'"Stillleaf Libre Baskerville", serif'},
 {id:'atkinson',label:'Atkinson Hyperlegible',stack:'"Stillleaf Atkinson Hyperlegible", sans-serif'},
 {id:'inter',label:'Inter',stack:'"Stillleaf Inter", sans-serif'},
 {id:'nunito',label:'Nunito Sans',stack:'"Stillleaf Nunito Sans", sans-serif'},
 {id:'source-sans',label:'Source Sans 3',stack:'"Stillleaf Source Sans 3", sans-serif'},
 {id:'georgia',label:'Georgia (alternate)',stack:'"Georgia", serif'},
 {id:'monospace',label:'Monospace',stack:'"monospace", serif'}
]);
export const FONT_IDS=Object.freeze(FONTS.map(f=>f.id));
export function fontStack(id){return FONTS.find(f=>f.id===id)?.stack??null}

/** Horizontal gutter and vertical page inset in CSS px, for regular and compact windows. */
export const MARGINS=Object.freeze({
 narrow:{label:'Narrow',gutter:[24,12],inset:[16,12]},
 normal:{label:'Normal',gutter:[44,20],inset:[32,22]},
 wide:{label:'Wide',gutter:[72,28],inset:[48,30]}
});
export const MARGIN_IDS=Object.freeze(Object.keys(MARGINS));
export function marginMetrics(id,compact){
 const m=MARGINS[id]??MARGINS.normal,i=compact?1:0;
 return {gutter:m.gutter[i],inset:m.inset[i]};
}

let context;
function width(font){context??=document.createElement('canvas').getContext('2d');context.font=font;return context.measureText('mmmmmmmmmmlli1WQ@#').width}
const availability=new Map();
/** A missing family falls back, so it measures like every generic fallback; an installed one differs from at least one. */
export function fontAvailable(id){
 const font=FONTS.find(f=>f.id===id);if(!font)return false;if(!font.probe)return true;
 if(!availability.has(id)){
  const family=font.probe.startsWith('ui-')?font.probe:`"${font.probe}"`;
  availability.set(id,['monospace','serif','sans-serif'].some(base=>width(`72px ${base}`)!==width(`72px ${family}, ${base}`)));
 }
 return availability.get(id);
}

const sample='the quick brown fox jumps over the lazy dog, then reads a quiet page of the book.';
/** Average advance of running text, in px, for a stack at a size; null when it cannot be measured. */
export function averageCharacterWidth(stack,sizePx){
 try{context??=document.createElement('canvas').getContext('2d');context.font=`${sizePx}px ${stack}`;const w=context.measureText(sample).width/sample.length;return Number.isFinite(w)&&w>0?w:null}catch{return null}
}
