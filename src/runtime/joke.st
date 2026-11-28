| joke |
joke := (Object << #LoomJoke slots: #(); package: 'Loom-Application') install.
joke class compile: 'runIn: execution
 ^ execution ask: (Message selector: #ask: arguments: { ''请讲一个笑话。'' })
  caller: thisContext through: execution'.
joke
