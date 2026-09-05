// Read-only, bounded probe of documented SumatraPDF 3.6 bracket syntax.
const fs = require('node:fs');
function parseSettings(source) {
  if (Buffer.byteLength(source,'utf8') > 8*1024*1024) throw Error('Settings file exceeds the 8 MiB probe limit.');
  const root={name:'root',values:{},children:[]}; const stack=[root];
  for(const raw of source.replace(/^\uFEFF/,'').split(/\r?\n/)) {
    const line=raw.trim(); if(!line||line.startsWith('#')||line.startsWith(';')) continue;
    if(line===']') { if(stack.length===1) throw Error('Unbalanced settings.'); stack.pop(); continue; }
    const opening=line.match(/^([A-Za-z0-9_]*)(?:\s*)\[$/);
    if(opening) { if(stack.length>32) throw Error('Settings nesting exceeds probe limit.'); const node={name:opening[1],values:{},children:[]};stack.at(-1).children.push(node);stack.push(node);continue; }
    const pair=line.match(/^([A-Za-z0-9_]+)\s*=\s*(.*)$/);
    if(!pair) throw Error('Unsupported settings syntax; no positions extracted.');
    if(Object.hasOwn(stack.at(-1).values,pair[1])) throw Error('Duplicate setting key.');
    stack.at(-1).values[pair[1]]=pair[2];
  }
  if(stack.length!==1) throw Error('Incomplete settings file; close SumatraPDF and retry with a copy.');
  if(root.values.RememberStatePerDocument==='false'||root.values.RememberOpenedFiles==='false') return [];
  const sections=root.children.filter(n=>n.name==='FileStates'); if(sections.length>1) throw Error('Ambiguous FileStates sections.');
  const candidates=[]; const paths=new Set();
  for(const node of sections[0]?.children??[]) {
    const v=node.values;
    if(!v.FilePath||!v.FilePath.toLowerCase().endsWith('.pdf')||v.IsMissing==='true'||v.UseDefaultState==='true'||!/^\d+$/.test(v.PageNo??'')) continue;
    const position=Number(v.PageNo); if(!Number.isSafeInteger(position)||position<1) continue;
    const key=v.FilePath.toLowerCase(); if(paths.has(key)) throw Error('Duplicate PDF path; no positions extracted.'); paths.add(key);
    candidates.push({source:'sumatrapdf-settings',documentPath:v.FilePath,position,unit:'pdf-page-index',evidence:'saved-position-only',liveReaderVerified:false});
  }
  return candidates;
}
if(require.main===module) {
  try {
    const file=process.argv[2]; if(!file) throw Error('Usage: node tools/sumatra-probe.cjs <copied SumatraPDF-settings.txt>');
    if(fs.statSync(file).size>8*1024*1024) throw Error('Settings file exceeds the 8 MiB probe limit.');
    const candidates=parseSettings(fs.readFileSync(file,'utf8'));
    console.log(JSON.stringify({warning:'Saved positions only. No journal changes, activity, duration, or live reader inference.',candidates},null,2));
  } catch(error) { console.error(error.message);process.exitCode=1; }
}
module.exports={parseSettings};
