import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
const FAST2SMS_API_KEY=Deno.env.get('FAST2SMS_API_KEY'), URL=Deno.env.get('SUPABASE_URL'), SERVICE=Deno.env.get('SUPA_SERVICE_ROLE_KEY')
const corsHeaders={
  'Access-Control-Allow-Origin':'*',
  'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods':'POST, OPTIONS',
}
const json=(b:unknown,s=200)=>new Response(JSON.stringify(b),{status:s,headers:{'Content-Type':'application/json','Cache-Control':'no-store',...corsHeaders}})
const norm=(v:string)=>v.replace(/\D/g,'').replace(/^91(?=\d{10}$)/,'')
async function sha256(v:string){const d=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(v));return Array.from(new Uint8Array(d)).map(x=>x.toString(16).padStart(2,'0')).join('')}
serve(async req=>{
 if(req.method==='OPTIONS') return new Response(null,{status:200,headers:corsHeaders})
 if(req.method!=='POST') return json({error:'Method Not Allowed'},405)
 const sb=createClient(URL!,SERVICE!); const {phone}=await req.json(); const p=norm(String(phone||'')); if(!/^\d{10}$/.test(p)) return json({error:'Invalid phone'},400)
 const since=new Date(Date.now()-10*60*1000).toISOString(); const {count}=await sb.from('otp_verification').select('id',{count:'exact',head:true}).eq('phone',p).eq('channel','sms').gte('created_at',since); if((count||0)>=3) return json({error:'Too many requests. Try later.'},429)
 const otp=String(crypto.getRandomValues(new Uint32Array(1))[0]%1000000).padStart(6,'0'); const salt=crypto.randomUUID(); const hash=await sha256(`${salt}:${otp}`); const expires=new Date(Date.now()+5*60*1000).toISOString()
 const r=await fetch('https://www.fast2sms.com/dev/bulkV2',{method:'POST',headers:{authorization:FAST2SMS_API_KEY!,'Content-Type':'application/json'},body:JSON.stringify({route:'otp',variables_values:otp,numbers:p})}); if(!r.ok) return json({error:'OTP provider error'},502)
 await sb.from('otp_verification').insert({phone:p,otp_code:null,otp_hash:`${salt}:${hash}`,channel:'sms',expires_at:expires,is_used:false,attempt_count:0,max_attempts:5})
 return json({success:true,expires_in:300})
})
