import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
const URL=Deno.env.get('SUPABASE_URL')
const SERVICE=Deno.env.get('SUPA_SERVICE_ROLE_KEY')||Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
const ANON=Deno.env.get('SUPABASE_ANON_KEY')
const corsHeaders={
  'Access-Control-Allow-Origin':'*',
  'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods':'POST, OPTIONS',
}
const json=(b:unknown,s=200)=>new Response(JSON.stringify(b),{status:s,headers:{'Content-Type':'application/json','Cache-Control':'no-store',...corsHeaders}})
const norm=(v:string)=>v.replace(/\D/g,'').replace(/^91(?=\d{10}$)/,'')
async function sha256(v:string){const d=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(v));return Array.from(new Uint8Array(d)).map(x=>x.toString(16).padStart(2,'0')).join('')}

/** Deterministic synthetic email so we can mint sessions via magiclink for phone OTP users. */
const phoneEmail=(p:string)=>`${p}@phone.kitpat.local`

async function ensureAuthUser(admin:ReturnType<typeof createClient>, userId:string, phone:string){
  const email=phoneEmail(phone)
  const phoneE164=`+91${phone}`
  const {data:existing}=await admin.auth.admin.getUserById(userId)
  if(existing?.user){
    const patch:Record<string,unknown>={}
    if(!existing.user.email) patch.email=email
    if(!existing.user.phone) patch.phone=phoneE164
    if(Object.keys(patch).length){
      patch.email_confirm=true
      patch.phone_confirm=true
      await admin.auth.admin.updateUserById(userId,patch)
    }
    return existing.user.email||email
  }
  const {error}=await admin.auth.admin.createUser({
    id:userId,
    email,
    email_confirm:true,
    phone:phoneE164,
    phone_confirm:true,
    user_metadata:{phone},
  })
  if(error){
    // Email/phone may already exist under this id after a partial create — re-check
    const {data:again}=await admin.auth.admin.getUserById(userId)
    if(again?.user) return again.user.email||email
    throw new Error(error.message||'Failed to create auth user')
  }
  return email
}

async function mintSession(admin:ReturnType<typeof createClient>, email:string){
  const {data:link,error:linkErr}=await admin.auth.admin.generateLink({type:'magiclink',email})
  if(linkErr||!link?.properties?.hashed_token) throw new Error(linkErr?.message||'Failed to generate session link')
  const anon=createClient(URL!,ANON!,{auth:{persistSession:false,autoRefreshToken:false}})
  const {data:verified,error:otpErr}=await anon.auth.verifyOtp({
    token_hash:link.properties.hashed_token,
    type:'email',
  })
  if(otpErr||!verified.session) throw new Error(otpErr?.message||'Failed to mint session')
  return verified.session
}

serve(async req=>{
 if(req.method==='OPTIONS') return new Response(null,{status:200,headers:corsHeaders})
 if(req.method!=='POST') return json({error:'Method Not Allowed'},405)
 const sb=createClient(URL!,SERVICE!,{auth:{persistSession:false,autoRefreshToken:false}})
 const body=await req.json(); const phone=norm(String(body.phone||'')), otp=String(body.otp||''), channel=String(body.channel||'sms'); if(!/^\d{10}$/.test(phone)||!/^\d{6}$/.test(otp)) return json({verified:false,error:'Invalid input'},400)
 const now=new Date().toISOString()
 const {data:rec}=await sb.from('otp_verification').select('id,otp_hash,expires_at,is_used,attempt_count,max_attempts').eq('phone',phone).eq('channel',channel).eq('is_used',false).order('created_at',{ascending:false}).limit(1).maybeSingle()
 if(!rec||rec.expires_at<=now) return json({verified:false,error:'Code expired, please request a new one'},400)
 if(rec.attempt_count>=rec.max_attempts) return json({verified:false,error:'Too many attempts'},429)
 const [salt,stored]=String(rec.otp_hash||'').split(':'); const actual=await sha256(`${salt}:${otp}`); if(!salt||actual!==stored){await sb.from('otp_verification').update({attempt_count:rec.attempt_count+1,last_attempt_at:new Date().toISOString()}).eq('id',rec.id);return json({verified:false,error:'Incorrect code, please try again'},400)}
 await sb.from('otp_verification').update({is_used:true,last_attempt_at:new Date().toISOString()}).eq('id',rec.id)
 // Create/fetch public.users via SECURITY DEFINER RPC (anon cannot INSERT users directly)
 const {data:user, error:userErr}=await sb.rpc('ensure_user_after_otp',{p_otp_id:rec.id,p_phone:phone})
 if(userErr||!user) return json({verified:false,error:'Verified but user create failed',detail:userErr?.message||null},500)

 // Link/create auth.users with the same id, then mint a real session for the frontend
 let session
 try{
  if(!ANON) throw new Error('SUPABASE_ANON_KEY not configured')
  const email=await ensureAuthUser(sb,user.id,phone)
  session=await mintSession(sb,email)
 }catch(e){
  return json({verified:false,error:'Verified but session mint failed',detail:e instanceof Error?e.message:String(e)},500)
 }

 return json({
  verified:true,
  user:{id:user.id,phone:user.phone,name:user.name,onboarding_completed:user.onboarding_completed,city:user.city,group_interest:user.group_interest},
  session:{access_token:session.access_token,refresh_token:session.refresh_token,expires_in:session.expires_in,expires_at:session.expires_at,token_type:session.token_type},
 })
})
