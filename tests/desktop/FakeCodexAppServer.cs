using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;

public static class FakeCodexAppServer {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static string threadId, turnId;
    static int serial;

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
        Event("turn/completed", new {threadId,turn=new {id=turnId,status,items=new object[0]}});
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
                var result = (Dictionary<string,object>)query["result"];
                Finish(Object.Equals(result["success"],true)?"object callback completed":"object callback failed",
                    Object.Equals(result["success"],true)?"completed":"failed");
                continue;
            }
            var method = (string)offered;
            if (method == "initialized") continue;
            var args = (Dictionary<string,object>)query["params"];
            switch (method) {
                case "initialize":
                    Reply(id,new { userAgent="Loom offline protocol fixture" }); break;
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
                    Reply(id,new {turn=new {id=turnId,status="inProgress"}});
                    var input=(Dictionary<string,object>)((System.Collections.IList)args["input"])[0];
                    var text=(string)input["text"];
                    Event("item/started",new {threadId,turnId,item=new {id="progress-"+turnId,type="agentMessage",phase="commentary",text="Starting"}});
                    Event("item/agentMessage/delta",new {threadId,turnId,itemId="progress-"+turnId,delta=" offline"});
                    if(text=="mock-active") break;
                    if(text=="Loom \u8c03\u7528\u4e86\u4f60\u3002") {
                        Send(new {id="tool-"+turnId,method="item/tool/call",@params=new {threadId,turnId,callId="tool-"+turnId,
                            tool="runtime_eval",arguments=new {code="loomReturn value: (loomMessage selector = #replyTo:usingContext: ifTrue: [ (loomMessage arguments first at: 'text'), ' reply' ] ifFalse: [ Dictionary new at: 'session' put: loomSessionId; at: 'argument' put: loomMessage arguments first; yourself ]). true"}}});
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
