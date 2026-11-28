using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;

public static class FakeCodexAppServer {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static string threadId, turnId, lateFailureTurn;
    static bool waitForHandoffRelease;
    static volatile bool waitForSilenceRelease;
    static int serial, toolSerial;
    static readonly Dictionary<string,Tuple<string,string>> toolOwners =
        new Dictionary<string,Tuple<string,string>>();
    static void Tool(string id, string source) {
        toolOwners.Add(id,Tuple.Create(threadId,turnId));
        Send(new {id,method="item/tool/call",@params=new {threadId,turnId,callId=id,
            tool="runtime_eval",arguments=new {code=source}}});
    }
    static readonly string ObjectInvocationCode = @"
| selector input prompt action staged gate deadline result attempts previous original entries tool context activities |
selector := loomMessage selector.
input := loomMessage arguments first.
selector = #fixtureBusiness: ifTrue: [
 loomReturn value: (input caseOf: {
   [ 'direct' ] -> [ nil ].
   [ 'inspect' ] -> [ (LMBusinessDisplayFixture new client: (LoomCodex session: loomSessionId); yourself) printString ].
   [ 'self' ] -> [ | first |
     first := (LoomCodex session: loomSessionId) fixtureOpinion: 'one'.
     {first. (LoomCodex session: loomSessionId) fixtureOpinion: 'two'} ].
   [ 'A' ] -> [ {'A'. (LoomCodex session: 'debate-b') fixtureBusiness: 'B'} ].
   [ 'B' ] -> [ {'B'. (LoomCodex session: 'debate-c') fixtureBusiness: 'C'} ].
   [ 'C' ] -> [ {'C'. (LoomCodex session: 'debate-a') fixtureOpinion: 'rollback'} ] }) ] ifFalse: [
(#(fixtureRecovery: fixtureCommitted: fixtureInterrupted: fixtureHandoff: fixtureHandoff:usingContext: fixtureHeldResult: fixtureSilentResult: fixtureNetworkResult: recover:after:) includes: selector) ifTrue: [
  selector caseOf: {
    [ #fixtureRecovery: ] -> [ 'fail-before-return' ].
    [ #fixtureCommitted: ] -> [ loomReturn value: input. 'fail-after-return' ].
    [ #fixtureInterrupted: ] -> [ 'interrupted' ].
    [ #fixtureHandoff: ] -> [ 'hold-for-handoff' ].
    [ #fixtureHandoff:usingContext: ] -> [ 'hold-for-handoff' ].
    [ #fixtureHeldResult: ] -> [ loomReturn value: input. 'hold-with-result' ].
    [ #fixtureSilentResult: ] -> [ loomReturn value: input. 'hold-with-silent-result' ].
    [ #fixtureNetworkResult: ] -> [ 'hold-for-network-result' ].
    [ #recover:after: ] -> [
      attempts := input attempts.
      previous := loomMessage arguments second.
      original := input message.
      ((attempts last at: 'id') = (previous at: 'id') and: [
        loomCaller method selector = #recover:after: ])
       ifFalse: [ self error: 'wrong recovery invocation' ].
      activities := input activities.
      entries := (activities activitySummariesForCall: (previous at: 'id') before: nil limit: 20) at: 'items'.
      tool := entries detect: [ :row | (row at: 'tool') = 'runtime_eval' ].
      ((((activities activityDetailAt: (tool at: 'seq')) at: 'data') at: 'result') at: 'ok')
       ifFalse: [ self error: 'old tool result is missing' ].
      original selector = #fixtureHandoff:usingContext: ifTrue: [
        context := original arguments second.
        (context source = 'mail' and: [ context messageId = 'fixture-source-message' and: [
         context threadId = 'fixture-mail-thread' and: [ context activities == activities ] ] ])
         ifFalse: [ self error: 'original source context is missing' ] ].
      (#(fixtureHandoff: fixtureHandoff:usingContext:) includes: original selector)
       ifTrue: [
        ((previous at: 'replaceCodexSession') = true and: [ (previous at: 'turnStatus') = 'interrupted' ])
         ifFalse: [ self error: 'missing handoff receipt' ].
        loomReturn value: original arguments first ]
       ifFalse: [
        original selector = #fixtureRecovery: ifFalse: [ self error: 'wrong original selector' ].
        attempts size = 1
         ifTrue: [
          (previous at: 'turnStatus') = 'failed' ifFalse: [ self error: 'missing failure receipt' ].
          'complete-without-return' ]
         ifFalse: [
          (attempts size = 2 and: [ (previous at: 'turnStatus') = 'completed' ])
           ifFalse: [ self error: 'wrong recovery attempt count' ].
          loomReturn value: original arguments first ] ] ] }
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
        context := loomMessage arguments second.
        (context source = 'conversation' and: [ context messageId = (input at: 'id') and: [
         context conversation == LoomConversation and: [ context activities == LoomNativeCodexHost registry ] ] ])
          ifFalse: [ self error: 'wrong desktop invocation context' ].
        prompt := input at: 'text'.
        (prompt beginsWith: 'browser fixture ') ifTrue: [
          action := (prompt endsWith: 'close-failed') ifTrue: [ 'close' ] ifFalse: [ prompt allButFirst: 16 ].
          loomReturn value: (Dictionary new at: 'text' put: prompt, ' reply'; at: 'browserAction' put: action; yourself)
        ] ifFalse: [ loomReturn value: prompt, ' reply' ]
      ] ifFalse: [
        (#(replyToWeixin:usingContext: replyToWeixinVoiceAndReturnCorrectedTranscripts:usingContext:) includes: selector) ifTrue: [
          (loomMessage arguments second source = 'weixin' and: [ loomSessionId = 'main' ])
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
true ] ]";

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
    static void AfterRelease(string path, Action action) {
        var release = new System.Threading.Thread(() => {
            for (int attempt=0; attempt<600; ++attempt) {
                if (File.Exists(path)) { action(); return; }
                System.Threading.Thread.Sleep(50);
            }
        });
        release.IsBackground=true;
        release.Start();
    }
    static void CompleteTool(Dictionary<string,object> result) {
        if (!Object.Equals(result["success"],true)) {
            Finish("object callback failed","failed");
            return;
        }
        var output = (Dictionary<string,object>)((System.Collections.IList)result["contentItems"])[0];
        var value = (Dictionary<string,object>)Json.DeserializeObject((string)output["text"]);
        if (Object.Equals(value["kind"],"subrequest")) {
            var requestId=Guid.Parse((string)value["requestId"]).ToString();
            string source="| sub word | sub := loomRun request: '"+requestId+"'. "+
                "(sub message selector = #fixtureOpinion: and: [sub caller notNil]) ifFalse: [self error: 'wrong subrequest']. "+
                "word := sub message arguments first. "+
                "loomRun answer: '"+requestId+"' with: (word caseOf: { "+
                "['display'] -> [(LoomCodex session: loomSessionId) fixtureOpinion: 'inner']. "+
                "['rollback'] -> ['rollback-', ((LoomCodex session: 'debate-b') fixtureOpinion: 'followup')] "+
                "} otherwise: [word, '-answered'])";
            Tool("business-"+(++toolSerial),source);
            return;
        }
        var action = value["value"] as string;
        switch (action) {
            case "fail-before-return":
                lateFailureTurn=turnId;
                Finish("","failed"); break;
            case "fail-after-return":
                Finish("","failed"); break;
            case "interrupted":
                Finish("","interrupted"); break;
            case "hold-for-handoff":
                waitForHandoffRelease=true;
                Event("item/completed",new {threadId,turnId,item=new {id="handoff-"+turnId,type="agentMessage",
                    phase="commentary",text="Fixture ready for handoff"}}); break;
            case "hold-with-result":
            case "hold-with-silent-result":
                waitForSilenceRelease=action=="hold-with-silent-result";
                Event("item/completed",new {threadId,turnId,item=new {id="handoff-"+turnId,type="agentMessage",
                    phase="commentary",text="Fixture ready for handoff"}}); break;
            case "hold-for-network-result":
                var waitingThread=threadId;
                var waitingTurn=turnId;
                Event("item/completed",new {threadId,turnId,item=new {id="handoff-"+turnId,type="agentMessage",
                    phase="commentary",text="Fixture ready for handoff"}});
                AfterRelease("release-fixture-network-result", () => {
                    var callId="network-tool-"+waitingTurn;
                    Send(new {id=callId,method="item/tool/call",@params=new {threadId=waitingThread,turnId=waitingTurn,callId,
                        tool="runtime_eval",arguments=new {code="loomReturn value: loomMessage arguments first. true"}}});
                });
                break;
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
                Tuple<string,string> owner;
                if (toolOwners.TryGetValue((string)id,out owner)) {
                    threadId=owner.Item1; turnId=owner.Item2; toolOwners.Remove((string)id);
                }
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
                    if (waitForSilenceRelease) {
                        Send(new {id,error=new {code=-32600,message="Previous turn is still running"}}); break;
                    }
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
                        Tool("tool-"+turnId,ObjectInvocationCode);
                    } else Finish(text+" \u56de\u6267","completed");
                    break;
                case "turn/interrupt":
                    bool silent=waitForSilenceRelease;
                    if (silent) File.AppendAllText("fixture-silent-interrupt",threadId+"\n"+turnId+"\n");
                    else Reply(id,new {});
                    if (waitForHandoffRelease || silent) {
                        waitForHandoffRelease=false;
                        string endedThread=threadId, endedTurn=turnId;
                        AfterRelease(silent ? "release-fixture-silence" : "release-fixture-handoff", () => {
                            if (silent) {
                                Reply(id,new {});
                                waitForSilenceRelease=false;
                            }
                            Event("turn/completed",new {threadId=endedThread,
                                turn=new {id=endedTurn,status="interrupted"}});
                        });
                    } else Finish("","interrupted");
                    break;
                default:
                    Send(new {id,error=new {code=-32601,message="Unexpected request "+method}}); break;
            }
        }
        return 0;
    }
}
