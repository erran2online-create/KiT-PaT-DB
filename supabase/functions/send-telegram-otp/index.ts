import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
const BOT=Deno.env.get('TELEGRAM_BOT_TOKEN'), CHAT=Deno.env.get('KITPAT_SUPPORT_CHAT_ID'), URL=Deno.env.get('SUPABASE_URL'), SERVICE=Deno.env.get('SUPA_SERVICE_ROLE_KEY')
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
 const since=new Date(Date.now()-10*60*1000).toISOString(); const {count}=await sb.from('otp_verification').select('id',{count:'exact',head:true}).eq('phone',p).eq('channel','telegram').gte('created_at',since); if((count||0)>=3) return json({error:'Too many requests. Try later.'},429)
 const otp=String(crypto.getRandomValues(new Uint32Array(1))[0]%1000000).padStart(6,'0'), salt=crypto.randomUUID(), hash=await sha256(`${salt}:${otp}`); const message=`🔐 Your KiT-PaT verification code is: ${otp}\n\nValid for 5 minutes. Do not share it.`
 const r=await fetch(`https://api.telegram.org/bot${BOT}/sendMessage`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({chat_id:CHAT,text:`${message}\n\nNumber: +91${p}`})}); if(!r.ok) return json({error:'Telegram provider error'},502)
 await sb.from('otp_verification').insert({phone:p,otp_code:null,otp_hash:`${salt}:${hash}`,channel:'telegram',expires_at:new Date(Date.now()+300000).toISOString(),is_used:false,attempt_count:0,max_attempts:5}); return json({success:true,expires_in:300})
})
