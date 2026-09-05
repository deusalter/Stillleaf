// Reading appearance: page themes, typefaces and margins. Stored ids are part of
// the saved-state contract (hosts validate them), so ids never change once shipped;
// labels can. `paper`, `sepia`, `dark`, `serif` and `sans` predate this table.

/** Page colours. `chrome` tones the reader bar and panels around the page. */
export const THEMES=Object.freeze([
 {id:'original',label:'Original',scheme:'light',background:'#FFFFFF',text:'#1D1D1F',link:'#0B63C4',selection:'#B4D5FE',chrome:'#F2F2F4',muted:'#6E6E73',panel:'#FAFAFB'},
 {id:'paper',label:'Stillleaf',scheme:'light',background:'#F0F7F3',text:'#183D33',link:'#087D65',selection:'#B9DCCE',chrome:'#DFECE7',muted:'#5E786E',panel:'#F6FAF7'},
 {id:'sepia',label:'Warm',scheme:'light',background:'#F6F1E3',text:'#403B2C',link:'#7A5A22',selection:'#E3D5A8',chrome:'#E7E5D8',muted:'#7A725D',panel:'#FBF7EC'},
 {id:'calm',label:'Calm',scheme:'light',background:'#EEE2CC',text:'#3B3024',link:'#80522A',selection:'#D8C39D',chrome:'#E2D4BA',muted:'#7B6A55',panel:'#F4EBDA'},
 {id:'focus',label:'Focus',scheme:'light',background:'#FFFBEF',text:'#1C1A16',link:'#6A4E12',selection:'#F1E2B6',chrome:'#F3EDDC',muted:'#6F6A5E',panel:'#FFFDF6'},
 {id:'quiet',label:'Quiet',scheme:'dark',background:'#4A4A4E',text:'#D6D6D9',link:'#B7CDEB',selection:'#6B6B72',chrome:'#3E3E42',muted:'#A7A7AD',panel:'#535358'},
 {id:'dark',label:'Dark',scheme:'dark',background:'#1C302D',text:'#E7F3EA',link:'#70DAB2',selection:'#466858',chrome:'#132422',muted:'#A1BDB2',panel:'#223833'},
 // Night keeps contrast low and dims illustrations for reading in a dark room.
 {id:'night',label:'Night',scheme:'dark',background:'#0D0D0E',text:'#ABABAF',link:'#8FB0D6',selection:'#34343A',chrome:'#050505',muted:'#7C7C82',panel:'#18181A',dimImages:true},
 {id:'white',label:'White',scheme:'light',background:'#FFFFFF',text:'#242729',link:'#225EAD',selection:'#B9DCCE',chrome:'#FFFFFF',muted:'#242729',panel:'#FFFFFF'},
 {id:'stone',label:'Stone',scheme:'light',background:'#E9E8E4',text:'#343534',link:'#4B615A',selection:'#B9DCCE',chrome:'#E9E8E4',muted:'#343534',panel:'#E9E8E4'},
 {id:'mist',label:'Mist',scheme:'light',background:'#EAF1F7',text:'#263C50',link:'#386B92',selection:'#B9DCCE',chrome:'#EAF1F7',muted:'#263C50',panel:'#EAF1F7'},
 {id:'forest',label:'Forest',scheme:'light',background:'#E4EFE6',text:'#234A35',link:'#286343',selection:'#B9DCCE',chrome:'#E4EFE6',muted:'#234A35',panel:'#E4EFE6'},
 {id:'dusk',label:'Dusk',scheme:'dark',background:'#302C3A',text:'#EDE4F1',link:'#D6B6EB',selection:'#466858',chrome:'#302C3A',muted:'#EDE4F1',panel:'#302C3A'},
 {id:'midnight',label:'Midnight',scheme:'dark',background:'#0D121A',text:'#D4DAE5',link:'#9CBFF2',selection:'#466858',chrome:'#0D121A',muted:'#D4DAE5',panel:'#0D121A'},
 {id:'custom',label:'Custom',scheme:'light',background:'#F0F7F3',text:'#183D33',link:'#087D65',selection:'#B9DCCE',chrome:'#F0F7F3',muted:'#183D33',panel:'#F0F7F3'}
]);
export const THEME_IDS=Object.freeze(['system',...THEMES.map(t=>t.id)]);
/** `system` follows the Mac: Stillleaf by day, Dark at night. */
export function resolveTheme(id,prefersDark){
 const chosen=id==='system'?(prefersDark?'dark':'paper'):id;
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
