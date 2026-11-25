using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;

public static class FakeCodexAppServer {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static string threadId, turnId, lateFailureTurn;
    static int serial;
    static readonly string ObjectInvocationCode = @"
| selector input prompt action staged gate deadline result attempts previous original |
selector := loomMessage selector.
input := loomMessage arguments first.
(#(fixtureRecovery: fixtureCommitted: fixtureInterrupted: continue:after:) includes: selector) ifTrue: [
  selector caseOf: {
    [ #fixtureRecovery: ] -> [ 'fail-before-return' ].
    [ #fixtureCommitted: ] -> [ loomReturn value: input. 'fail-after-return' ].
    [ #fixtureInterrupted: ] -> [ 'interrupted' ].
    [ #continue:after: ] -> [
      attempts := input attempts.
      previous := loomMessage arguments second.
      original := input message.
      (original selector = #fixtureRecovery: and: [
       (attempts last at: 'id') = (previous at: 'id') and: [
        loomCaller method selector = #continue:after: ] ])
       ifFalse: [ self error: 'wrong recovery invocation' ].
      attempts size = 1
       ifTrue: [
        (previous at: 'turnStatus') = 'failed' ifFalse: [ self error: 'missing failure receipt' ].
        'complete-without-return' ]
       ifFalse: [
        (attempts size = 2 and: [ (previous at: 'turnStatus') = 'completed' ])
         ifFalse: [ self error: 'wrong recovery attempt count' ].
        loomReturn value: original arguments first ] ] }
] ifFalse: [
selector = #closeBrowserUsedFor: ifTrue: [
    staged := LoomConversation storage: 'staged-browser-reply' options:
      (Dictionary new at: 'id' put: (LoomConversation records last at: 'id'); yourself).
    input = ((staged at: 'invocation') at: 'id') ifFalse: [ self error: 'wrong cleanup target' ].
    LMPlatformTools writeJSON: { loomSessionId. input } to: ExperimentRoot / 'browser-close-started.json'.
    gate := ExperimentRoot / 'browser-close-release'.
    deadline := DateAndTime now + 30 seconds.
    [ gate exists or: [ DateAndTime now >= deadline ] ] whileFalse: [ (Delay forMilliseconds: 50) wait ].
    gate exists ifFalse: [ self error: 'fixture close gate timed out' ].
    result := Dictionary new at: 'ok' put: true; yourself.
    (staged at: 'text') = 'browser fixture close-failed reply' ifTrue: [
      result at: 'ok' put: false; at: 'error' put: 'fixture could not close browser' ].
    loomReturn value: result
] ifFalse: [
    selector = #correctSpeechTranscript: ifTrue: [ loomReturn value: input, ' corrected' ] ifFalse: [
      selector = #replyTo:usingContext: ifTrue: [
        prompt := input at: 'text'.
        (prompt beginsWith: 'browser fixture ') ifTrue: [
          action := (prompt endsWith: 'close-failed') ifTrue: [ 'close' ] ifFalse: [ prompt allButFirst: 16 ].
          loomReturn value: (Dictionary new at: 'text' put: prompt, ' reply'; at: 'browserAction' put: action; yourself)
        ] ifFalse: [ loomReturn value: prompt, ' reply' ]
      ] ifFalse: [
        (#(replyToWeixin:usingContext: replyToWeixinVoiceAndReturnCorrectedTranscripts:usingContext:) includes: selector) ifTrue: [
          ((loomMessage arguments second at: 'source') = 'weixin' and: [ loomSessionId = 'main' ])
            ifFalse: [ self error: 'wrong Weixin invocation context' ].
          selector = #replyToWeixinVoiceAndReturnCorrectedTranscripts:usingContext: ifTrue: [
            (((input at: 'attachments') first at: 'transcript') = 'fixture transcript')
              ifFalse: [ self error: 'missing Weixin transcript' ].
            loomReturn value: (Dictionary new at: 'text' put: (input at: 'text'), ' voice reply';
              at: 'correctedTranscripts' put: { Dictionary new
                at: 'id' put: ((input at: 'attachments') first at: 'id');
                at: 'text' put: 'corrected fixture transcript'; yourself }; yourself)
          ] ifFalse: [ loomReturn value: (input at: 'text'), ' reply' ]
        ] ifFalse: [
          loomReturn value: (Dictionary new at: 'session' put: loomSessionId; at: 'argument' put: input; yourself) ] ] ] ].
true ]";

    static void Send(object value) {
        Console.WriteLine(Json.Serialize(value));
        Console.Out.Flush();
    }
    static void Reply(object id, object result) {
        Send(new { id, result });
    }
    static void Event(string method, object fields) {
        Send(new { method, @params = fields });
    }
    static void Finish(string text, string status) {
        if (status == "completed") Event("item/completed", new {threadId, turnId,
            item = new {id="answer-"+turnId,type="agentMessage",phase="final_answer",text}});
        if (status == "failed")
            Event("turn/completed", new {threadId,turn=new {id=turnId,status,items=new object[0],
                error=new { message="fixture failure", codexErrorInfo="fixtureError" }}});
        else
            Event("turn/completed", new {threadId,turn=new {id=turnId,status,items=new object[0]}});
    }
    static void CompleteTool(Dictionary<string,object> result) {
        if (!Object.Equals(result["success"],true)) {
            Finish("object callback failed","failed");
            return;
        }
        var output = (Dictionary<string,object>)((System.Collections.IList)result["contentItems"])[0];
        var value = (Dictionary<string,object>)Json.DeserializeObject((string)output["text"]);
        switch (value["value"] as string) {
            case "fail-before-return":
                lateFailureTurn=turnId;
                Finish("","failed"); break;
            case "fail-after-return":
                Finish("","failed"); break;
            case "interrupted":
                Finish("","interrupted"); break;
            default:
                Finish("object callback completed","completed"); break;
        }
    }
    public static int Main() {
        Console.InputEncoding = new UTF8Encoding(false);
        Console.OutputEncoding = new UTF8Encoding(false);
        string line;
        while ((line = Console.ReadLine()) != null) {
            var query = Json.Deserialize<Dictionary<string,object>>(line);
            object id, offered;
            query.TryGetValue("id", out id);
            if (!query.TryGetValue("method", out offered)) {
                CompleteTool((Dictionary<string,object>)query["result"]);
                continue;
            }
            var method = (string)offered;
            if (method == "initialized") continue;
            var args = (Dictionary<string,object>)query["params"];
            switch (method) {
                case "initialize":
                    Reply(id,new { userAgent="Loom offline protocol fixture" }); break;
                case "model/list":
                    Reply(id,new { data=new[] { new { model="offline", displayName="Offline fixture",
                        defaultReasoningEffort="medium",
                        supportedReasoningEfforts=new[] { new { reasoningEffort="medium" } } } } }); break;
                case "thread/start":
                    threadId="fixture-"+Guid.NewGuid().ToString("D");
                    Reply(id,new { thread=new { id=threadId }, model="offline" }); break;
                case "thread/resume":
                    threadId=(string)args["threadId"];
                    Reply(id,new { thread=new { id=threadId }, model="offline" }); break;
                case "thread/name/set":
                    Reply(id,new { }); break;
                case "turn/start":
                    threadId=(string)args["threadId"];
                    turnId="turn-"+(++serial);
                    if (lateFailureTurn != null) {
                        Event("turn/completed",new {threadId,turn=new {id=lateFailureTurn,status="failed"}});
                        lateFailureTurn=null;
                    }
                    Reply(id,new {turn=new {id=turnId,status="inProgress"}});
                    var input=(Dictionary<string,object>)((System.Collections.IList)args["input"])[0];
                    var text=(string)input["text"];
                    Event("item/started",new {threadId,turnId,item=new {id="progress-"+turnId,type="agentMessage",phase="commentary",text="Starting"}});
                    Event("item/agentMessage/delta",new {threadId,turnId,itemId="progress-"+turnId,delta=" offline"});
                    if(text=="mock-active") break;
                    if(text=="Loom \u8c03\u7528\u4e86\u4f60\u3002") {
                        Event("item/started",new {threadId,turnId,item=new {id="draft-"+turnId,type="agentMessage",phase="final_answer",text="Unpublished draft"}});
                        Send(new {id="tool-"+turnId,method="item/tool/call",@params=new {threadId,turnId,callId="tool-"+turnId,
                            tool="runtime_eval",arguments=new {code=ObjectInvocationCode}}});
                    } else Finish(text+" \u56de\u6267","completed");
                    break;
                case "turn/interrupt":
                    Reply(id,new {});
                    Finish("","interrupted");
                    break;
                default:
                    Send(new {id,error=new {code=-32601,message="Unexpected request "+method}}); break;
            }
        }
        return 0;
    }
}
