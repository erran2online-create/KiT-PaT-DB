import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
const URL=Deno.env.get('SUPABASE_URL'), SERVICE=Deno.env.get('SUPA_SERVICE_ROLE_KEY')
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
 const sb=createClient(URL!,SERVICE!); const body=await req.json(); const phone=norm(String(body.phone||'')), otp=String(body.otp||''), channel=String(body.channel||'sms'); if(!/^\d{10}$/.test(phone)||!/^\d{6}$/.test(otp)) return json({verified:false,error:'Invalid input'},400)
 const now=new Date().toISOString()
 const {data:rec}=await sb.from('otp_verification').select('id,otp_hash,expires_at,is_used,attempt_count,max_attempts').eq('phone',phone).eq('channel',channel).eq('is_used',false).order('created_at',{ascending:false}).limit(1).maybeSingle()
 if(!rec||rec.expires_at<=now) return json({verified:false,error:'Code expired, please request a new one'},400)
 if(rec.attempt_count>=rec.max_attempts) return json({verified:false,error:'Too many attempts'},429)
 const [salt,stored]=String(rec.otp_hash||'').split(':'); const actual=await sha256(`${salt}:${otp}`); if(!salt||actual!==stored){await sb.from('otp_verification').update({attempt_count:rec.attempt_count+1,last_attempt_at:new Date().toISOString()}).eq('id',rec.id);return json({verified:false,error:'Incorrect code, please try again'},400)}
 await sb.from('otp_verification').update({is_used:true,last_attempt_at:new Date().toISOString()}).eq('id',rec.id)
 // Create/fetch public.users via SECURITY DEFINER RPC (anon cannot INSERT users directly)
 const {data:user, error:userErr}=await sb.rpc('ensure_user_after_otp',{p_otp_id:rec.id,p_phone:phone})
 if(userErr||!user) return json({verified:false,error:'Verified but user create failed',detail:userErr?.message||null},500)
 return json({verified:true,user:{id:user.id,phone:user.phone,name:user.name,onboarding_completed:user.onboarding_completed,city:user.city,group_interest:user.group_interest}})
})
