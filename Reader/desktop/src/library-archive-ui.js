"use strict";
// Separate from the journal editor: archives never write an active journal projection.
(() => {
  const api=window.stillleafLibrary,trigger=document.getElementById('library-archive');
  const panel=document.createElement('dialog');panel.id='archive-dialog';panel.setAttribute('aria-labelledby','archive-title');
  const title=document.createElement('h2');title.id='archive-title';title.textContent='Library archive';
  const description=document.createElement('p');description.textContent='Save your journal, notes, reading settings and managed EPUBs together. Your original files stay where they are.';
  const status=document.createElement('p');status.setAttribute('role','status');
  const error=document.createElement('p');error.setAttribute('role','alert');
  const saved=document.createElement('div');
  const footer=document.createElement('footer');
  let busy=false;
  function button(label,action){const b=document.createElement('button');b.type='button';b.textContent=label;b.className='quiet';b.onclick=()=>run(action);return b;}
  async function run(action){if(busy)return;busy=true;error.textContent='';for(const b of panel.querySelectorAll('button'))b.disabled=true;
    try{await action();}catch(e){error.textContent=e.message;}finally{busy=false;for(const b of panel.querySelectorAll('button'))b.disabled=false;}}
  async function invoke(action,id){const result=await api.archive(action,id);if(result?.error)throw Error(result.error);return result;}
  async function refresh(){const result=await invoke('list');saved.replaceChildren();
    const heading=document.createElement('h3');heading.textContent='Preserved recovery archives';saved.append(heading);
    const explanation=document.createElement('p');explanation.textContent='Preserved archives are kept for recovery and export. They do not add books, replace notes, or contribute to your reading totals.';saved.append(explanation);
    if(result.warnings?.length){const warning=document.createElement('p');warning.textContent=result.warnings.join(' ');saved.append(warning);}
    if(!result.archives?.length){const empty=document.createElement('p');empty.textContent='No recovery archives saved here yet.';saved.append(empty);}
    for(const archive of result.archives??[]){const row=document.createElement('p');const text=document.createElement('span');text.textContent=`${archive.epubs} EPUBs · ${archive.readerStates} reader snapshots · ${archive.journals} journals `;row.append(text,button('Export recovery copy…',async()=>{const r=await invoke('export-preserved',archive.id);if(r.exported)status.textContent='Recovery archive exported unchanged.';}));saved.append(row);}
  }
  footer.append(button('Export complete archive…',async()=>{const r=await invoke('export');if(r.exported)status.textContent=`Archive exported: ${r.books} books, ${r.readerStates} reader snapshots and ${r.epubs} EPUBs.`;}),button('Preserve an archive…',async()=>{const r=await invoke('preserve');if(r.preserved){status.textContent=r.identical?'This recovery archive is already preserved.':'Recovery archive preserved. Your active Library and reading totals are unchanged.';await refresh();}}));
  const close=button('Close',async()=>panel.close());footer.append(close);
  panel.append(title,description,status,error,saved,footer);document.body.append(panel);
  panel.addEventListener('cancel',event=>{if(busy)event.preventDefault();});
  trigger.onclick=()=>{if(panel.open)return;status.textContent='';error.textContent='';panel.showModal();void run(refresh);};
})();
