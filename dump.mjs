import { readFileSync } from 'node:fs';
export function parse(b){const dv=new DataView(b.buffer,b.byteOffset,b.byteLength);const version=dv.getUint32(23,true);
const wide=version>=7500;const rd=(o)=>wide?Number(dv.getBigUint64(o,true)):dv.getUint32(o,true);const hdr=wide?25:13;
function node(off){const end=rd(off),num=rd(off+(wide?8:4));const nameLen=b[off+(wide?24:12)];
if(end===0)return[null,off+hdr];let p=off+hdr;const name=new TextDecoder().decode(b.subarray(p,p+nameLen));p+=nameLen;
const props=[];for(let i=0;i<num;i++){const t=String.fromCharCode(b[p]);p+=1;
if(t==='C'){props.push(b[p]!==0);p+=1;}else if(t==='Y'){props.push(dv.getInt16(p,true));p+=2;}
else if(t==='I'){props.push(dv.getInt32(p,true));p+=4;}else if(t==='F'){props.push(dv.getFloat32(p,true));p+=4;}
else if(t==='D'){props.push(dv.getFloat64(p,true));p+=8;}else if(t==='L'){props.push(Number(dv.getBigInt64(p,true)));p+=8;}
else if(t==='S'||t==='R'){const n=dv.getUint32(p,true);p+=4;props.push(t==='S'?new TextDecoder().decode(b.subarray(p,p+n)):{raw:n});p+=n;}
else{const n=dv.getUint32(p,true),bl=dv.getUint32(p+8,true);p+=12+bl;props.push({a:t,n});}}
const kids=[];while(p<end){const[k,nx]=node(p);p=nx;if(!k)break;kids.push(k);}
return[{name,props,children:kids},end];}
let off=27;const out=[];while(true){const[n,nx]=node(off);off=nx;if(!n)break;out.push(n);}
return{version,nodes:out};}
const show=(p)=>typeof p==='string'?JSON.stringify(p.length>34?p.slice(0,34)+'…':p):(p&&p.a?`${p.a}[${p.n}]`:(p&&p.raw!==undefined?`raw[${p.raw}]`:p));
function tree(ns,d,max,out){for(const n of ns){out.push('  '.repeat(d)+n.name+' '+n.props.map(show).join(' '));
if(d<max)tree(n.children,d+1,max,out);else if(n.children.length)out.push('  '.repeat(d+1)+'…'+n.children.length+' children');}}
const {version,nodes}=parse(new Uint8Array(readFileSync(process.argv[2]).buffer));
console.log('VERSION', version);
const lines=[];tree(nodes,0,Number(process.argv[3]||2),lines);
console.log(lines.join('\n'));
