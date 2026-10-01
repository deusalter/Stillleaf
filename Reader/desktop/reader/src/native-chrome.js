// The host receives UI state, never locators/evidence or a second persisted model.
export function nativeChromeAdapter({edition,ready,current,definitions,status=()=>({}),perform,visibility}) {
 let active=false,lastRequest=0,lastSignature='';
 const commands=new Set(['activate','deactivate','contents','notes','search','next','previous','bookmark','focus','preferences','reset','policy']);
 const ui=()=>({version:1,editionId:edition(),preferences:current(),definitions:definitions(),...status()});
 return Object.freeze({
  async dispatch(request){
   if(!request||request.version!==1||request.editionId!==edition()||!ready()||!Number.isSafeInteger(request.id)||request.id<=lastRequest||!commands.has(request.command)||Object.keys(request).some(k=>!['version','editionId','id','command','payload'].includes(k)))throw Error('Reader control request is unavailable or invalid.');
   if(!active&&request.command!=='activate')throw Error('Native controls are not connected.');
   if(request.command==='preferences'){
    const p=request.payload;if(!p||Array.isArray(p)||typeof p!=='object'||Object.keys(p).some(k=>!Object.hasOwn(current(),k))||Object.values(p).some(v=>v!==null&&!['string','number','boolean'].includes(typeof v))||Object.values(p).some(v=>typeof v==='number'&&!Number.isFinite(v)))throw Error('Invalid reading preferences.');
   }else if(request.command==='policy'){
    if(!request.payload||Object.keys(request.payload).some(k=>!['reduceMotion','reduceTransparency','increaseContrast'].includes(k))||Object.values(request.payload).some(v=>typeof v!=='boolean'))throw Error('Invalid display policy.');
   }else if(request.payload!==undefined)throw Error('Unexpected reader control payload.');
   lastRequest=request.id;
   if(request.command==='activate'||request.command==='deactivate') {active=request.command==='activate';try{await visibility(active)}catch(error){active=false;await visibility(false);throw error}}
   else await perform(request.command,request.payload);
   return {requestId:request.id,...ui()};
  },
  changed(emit){if(!active||!ready())return;const value=ui(),signature=JSON.stringify([value.preferences,status()]);if(signature!==lastSignature){lastSignature=signature;emit(value)}},
  disconnect(){active=false;lastSignature='';visibility(false,true)},
 });
}
