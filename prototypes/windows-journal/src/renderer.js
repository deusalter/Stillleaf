const $ = selector => document.querySelector(selector);
let state, selected, pendingDelete;
const today = () => { const d=new Date(); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`; };
const el = (tag, content, cls) => { const node=document.createElement(tag); node.textContent=content; if(cls) node.className=cls; return node; };
const numeric = value => value.trim() === '' ? null : Number(value);
function announce(text, error=false) { $('#message').textContent=text; $('#message').classList.toggle('error',error); }
async function call(action, input) { const result=await window.journal[action](input); if(result.error) throw Error(result.error); if(result.state) state=result.state; return result; }
function render() {
  $('#book-count').textContent=state.books.length;
  $('#books').replaceChildren();
  for(const book of state.books) {
    const button=el('button',book.title); button.append(el('small',book.author || book.status)); button.setAttribute('aria-current',String(book.id===selected));
    button.onclick=()=>{ selected=book.id; $('#entry-form').reset(); $('#date').value=today(); announce(''); render(); }; $('#books').append(button);
  }
  const book=state.books.find(b=>b.id===selected);
  $('#empty').hidden=!!book; $('#detail').hidden=!book;
  if(!book) return;
  $('#heading').textContent=book.title; $('#byline').textContent=book.author || 'Your reading, at your own pace.'; $('#status').value=book.status;
  const entries=state.entries.filter(e=>e.bookId===selected).map((e,i)=>({...e,order:i})).sort((a,b)=>b.date.localeCompare(a.date)||b.order-a.order);
  const position=entries.find(e=>e.position!==null)?.position ?? null;
  $('#position').textContent=position===null?'Not set':`Page ${position}${book.totalPages ? ` of ${book.totalPages}`:''}`;
  $('#progress').hidden=position===null||!book.totalPages; $('#progress').max=book.totalPages||1; $('#progress').value=position||0; $('#progress').setAttribute('aria-label','Book position');
  $('#pages').textContent=entries.reduce((n,e)=>n+(e.pagesRead??0),0);
  $('#minutes').textContent=entries.some(e=>e.minutes!==null)?Number(entries.reduce((n,e)=>n+(e.minutes??0),0).toFixed(2)):'—';
  $('#entry-form [name=position]').max=book.totalPages??1000000;
  $('#history').replaceChildren();
  if(!entries.length) $('#history').append(el('p','No entries yet. Your first note will appear here.','hint'));
  for(const entry of entries) {
    const row=el('article','','history-item'); const date=new Date(entry.date+'T12:00:00'); row.append(el('h3',date.toLocaleDateString(undefined,{day:'numeric',month:'long',year:'numeric'})));
    const details=[]; if(entry.position!==null) details.push(`Position: page ${entry.position}`); if(entry.pagesRead!==null) details.push(`${entry.pagesRead} pages read`); if(entry.minutes!==null) details.push(`${entry.minutes} minutes`);
    if(details.length) row.append(el('p',details.join(' • '))); if(entry.note) row.append(el('p',entry.note));
    const remove=el('button','Remove entry','remove'); remove.onclick=()=>{pendingDelete=entry.id;$('#delete-dialog').showModal();}; row.append(remove); $('#history').append(row);
  }
}
function openBook(){ $('#book-error').textContent=''; $('#book-dialog').showModal(); }
$('#new-book').onclick=openBook; $('#empty-add').onclick=openBook; $('#cancel').onclick=()=>$('#book-dialog').close();
$('#book-form').onsubmit=async event=>{
  event.preventDefault(); const button=event.submitter; button.disabled=true;
  try { const data=Object.fromEntries(new FormData(event.target)); data.totalPages=numeric(data.totalPages); await call('addBook',data); selected=state.books.at(-1).id; event.target.reset(); $('#entry-form').reset(); $('#date').value=today(); $('#book-dialog').close(); render(); announce('Book added.'); } catch(error){$('#book-error').textContent=error.message;} finally{button.disabled=false;}
};
$('#entry-form').onsubmit=async event=>{
  event.preventDefault(); const button=event.submitter; button.disabled=true;
  try { const data=Object.fromEntries(new FormData(event.target)); for(const key of ['position','pagesRead','minutes']) data[key]=numeric(data[key]); await call('addEntry',{...data,bookId:selected}); event.target.reset(); $('#date').value=today(); render(); announce('Entry saved on this computer.'); } catch(error){announce(error.message,true);} finally{button.disabled=false;}
};
$('#status').onchange=async event=>{try{await call('setStatus',{id:selected,status:event.target.value});render();announce('Shelf updated.');}catch(error){render();announce(error.message,true);}};
$('#keep-entry').onclick=()=>$('#delete-dialog').close();
$('#confirm-delete').onclick=async()=>{try{await call('deleteEntry',{id:pendingDelete});$('#delete-dialog').close();render();announce('Entry removed. Add a new entry to correct it.');}catch(error){$('#delete-dialog').close();announce(error.message,true);}};
$('#export').onclick=async()=>{try{const result=await call('export');if(!result.canceled)announce('Journal exported.');}catch(error){announce(error.message,true);}};
(async()=>{try{await call('read');selected=state.books[0]?.id;$('#date').value=today();$('#date').max=today();render();}catch(error){announce(error.message,true);}})();
