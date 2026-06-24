/**
 * Runnable demo for @zaq/ai-sdk. One Bun server: the `/api/chat` route is the
 * REAL adapter (aguiHttpAgentEventStream -> aguiToUIMessageStream), the page is
 * a plain-fetch client that renders the streamed UIMessageChunks token by token.
 *
 *   ZAQ_AGUI_URL=http://localhost:4100 ZAQ_AGUI_TOKEN=dev-agui-token \
 *     bun run example/server.ts
 *   # open http://localhost:3333
 *
 * ponytail: client parses the UIMessage SSE stream by hand (text-delta only) so
 * the demo needs no bundler/React. A real app uses `useChat` from @ai-sdk/react
 * against this exact route — see README.
 */
import { createUIMessageStreamResponse, generateId } from "ai";
import {
	aguiHttpAgentEventStream,
	aguiToUIMessageStream,
	toAGUIMessages,
} from "../src/index";

const ZAQ_URL = process.env.ZAQ_AGUI_URL ?? "http://localhost:4100";
const ZAQ_TOKEN = process.env.ZAQ_AGUI_TOKEN ?? "dev-agui-token";
const PORT = Number(process.env.PORT ?? 3333);

// Advertised so ZAQ takes its streaming ReAct path (the plain path emits one delta).
const RENDER_WIDGET_TOOL = {
	name: "render_widget",
	description: "Render a markdown/table/bar widget in the chat.",
	parameters: {
		type: "object",
		properties: { type: { type: "string" }, title: { type: "string" }, data: {} },
		required: ["type", "data"],
	},
};

async function chat(req: Request): Promise<Response> {
	const { messages, threadId } = await req.json();
	const events = aguiHttpAgentEventStream({
		url: `${ZAQ_URL}/ag-ui/runs`,
		token: ZAQ_TOKEN, // held server-side; never sent to the browser
		input: {
			threadId: threadId ?? generateId(),
			runId: generateId(),
			state: {},
			messages: toAGUIMessages(messages),
			tools: [RENDER_WIDGET_TOOL],
			context: [],
			forwardedProps: {},
		},
		signal: req.signal,
	});
	return createUIMessageStreamResponse({ stream: aguiToUIMessageStream(events) });
}

Bun.serve({
	port: PORT,
	routes: {
		"/api/chat": { POST: chat },
		"/": () => new Response(PAGE, { headers: { "content-type": "text/html" } }),
	},
});
console.log(`@zaq/ai-sdk demo on http://localhost:${PORT}  (ZAQ: ${ZAQ_URL})`);

const PAGE = /* html */ `<!doctype html><meta charset=utf8>
<title>@zaq/ai-sdk demo</title>
<style>
 body{font:15px system-ui;max-width:680px;margin:40px auto;padding:0 16px;background:#0d0a1f;color:#ece9ff}
 #log{min-height:240px;display:flex;flex-direction:column;gap:10px;margin:16px 0}
 .msg{padding:10px 14px;border-radius:12px;white-space:pre-wrap}
 .user{background:#2a2156;align-self:flex-end} .bot{background:#171331;border:1px solid #2e2857}
 form{display:flex;gap:8px} input{flex:1;padding:10px;border-radius:10px;border:1px solid #2e2857;background:#11102a;color:#fff}
 button{padding:10px 16px;border-radius:10px;border:0;background:#6d5efc;color:#fff;font-weight:600}
 .note{font-size:12px;color:#a39ccc}
</style>
<h2>@zaq/ai-sdk — live stream</h2>
<div id=log></div>
<form id=f><input id=i placeholder="Pose une question…" autocomplete=off autofocus><button>Envoyer</button></form>
<script type=module>
const log=document.getElementById('log'), f=document.getElementById('f'), i=document.getElementById('i');
const threadId=crypto.randomUUID(); const messages=[];
const bubble=(cls,txt='')=>{const d=document.createElement('div');d.className='msg '+cls;d.textContent=txt;log.appendChild(d);return d};
f.onsubmit=async e=>{
  e.preventDefault(); const text=i.value.trim(); if(!text)return; i.value='';
  messages.push({id:crypto.randomUUID(),role:'user',parts:[{type:'text',text}]});
  bubble('user',text); const bot=bubble('bot'); let answer='';
  const res=await fetch('/api/chat',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({messages,threadId})});
  const reader=res.body.getReader(), dec=new TextDecoder(); let buf='';
  for(;;){const{done,value}=await reader.read(); if(done)break; buf+=dec.decode(value,{stream:true});
    let n; while((n=buf.indexOf('\\n\\n'))>=0){const line=buf.slice(0,n).replace(/^data: /,'');buf=buf.slice(n+2);
      if(line==='[DONE]')continue; let ev; try{ev=JSON.parse(line)}catch{continue}
      if(ev.type==='text-delta'){answer+=ev.delta; bot.textContent=answer}
      else if(ev.type==='tool-input-available'){const w=bubble('bot note');w.textContent='🧩 widget: '+JSON.stringify(ev.input).slice(0,200)}
    }}
  messages.push({id:crypto.randomUUID(),role:'assistant',parts:[{type:'text',text:answer}]});
};
</script>`;
