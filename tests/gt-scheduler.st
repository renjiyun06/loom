"Run inside the disposable application fixture using a separate scheduling database."
| directory scheduler reopened due first second crashed queued resumed items background deadline |
directory := ExperimentRoot / 'schedule-test'.
scheduler := LMScheduler new initializeAt: directory; yourself.
scheduler tasks isEmpty ifFalse: [ self error: 'Scheduler seeded a task' ].
due := (DateAndTime readFrom: '2026-11-26T07:00:00+08:00' readStream) asUnixTime.
scheduler
 configureDaily: 'daily' handler: 'collect' at: (Time hour: 7 minute: 0 second: 0) utcOffsetMinutes: 480 enabled: true.
scheduler
 configureDaily: 'disabled' handler: 'collect' at: (Time hour: 7 minute: 0 second: 0) utcOffsetMinutes: 480 enabled: false.
scheduler enqueueDueAt: due - 1.
(scheduler claimNextAt: due - 1) ifNotNil: [ self error: 'Task ran before its local time' ].
scheduler enqueueDueAt: due.
scheduler enqueueDueAt: due + 10.
first := scheduler claimNextAt: due + 10.
((first at: 'taskId') = 'daily' and: [ (first at: 'scheduledAt') = due and: [
 (first at: 'triggeredAt') = due and: [ (first at: 'startedAt') = (due + 10) ] ] ])
 ifFalse: [ self error: 'Wrong trigger or start time' ].
(scheduler claimNextAt: due + 10) ifNotNil: [ self error: 'Duplicate or disabled task ran' ].
scheduler registerHandler: 'collect' do: [ :run |
 Dictionary new at: 'runId' put: (run at: 'id'); at: 'notificationIds' put: #('notice-1'); yourself ].
scheduler execute: first.
items := scheduler runsFor: 'daily' limit: 10.
(items size = 1 and: [ (items first at: 'status') = 'completed' and: [
 ((items first at: 'result') at: 'runId') = (first at: 'id') and: [
 ((items first at: 'result') at: 'notificationIds') = #('notice-1') ] ] ])
 ifFalse: [ self error: 'Task result was not saved' ].
scheduler enqueueDueAt: due + 86400.
second := scheduler claimNextAt: due + 86400.
scheduler registerHandler: 'collect' do: [ :run | self error: 'fixture handler failure' ].
scheduler execute: second.
items := scheduler runsFor: 'daily' limit: 10.
((items first at: 'status') = 'failed' and: [ (items first at: 'errorStage') = 'execute'
 and: [ (items first at: 'error') = 'fixture handler failure' ] ])
 ifFalse: [ self error: 'Handler failure was not saved' ].
scheduler enqueueDueAt: due + (2 * 86400).
crashed := scheduler claimNextAt: due + (2 * 86400).
scheduler enqueueDueAt: due + (3 * 86400).
queued := (scheduler runsFor: 'daily' limit: 1) first.
reopened := LMScheduler new initializeAt: directory; yourself.
items := reopened runsFor: 'daily' limit: 10.
((items second at: 'id') = (crashed at: 'id') and: [
 (items second at: 'status') = 'interrupted' and: [ (items second at: 'errorStage') = 'restart'
 and: [ (items second at: 'finishedAt') notNil ] ] ])
 ifFalse: [ self error: 'Interrupted task was not retained' ].
reopened enqueueDueAt: due + (3 * 86400).
resumed := reopened claimNextAt: due + (3 * 86400).
(resumed at: 'id') = (queued at: 'id')
 ifFalse: [ self error: 'Queued task lost its original run ID' ].
reopened execute: resumed.
items := reopened runsFor: 'daily' limit: 10.
(items size = 4 and: [ (items first at: 'errorStage') = 'dispatch' ])
 ifFalse: [ self error: 'Restart duplicated a slot or lost the dispatch failure' ].
background := LMScheduler new initializeAt: directory / 'worker'; yourself.
background registerHandler: 'collect' do: [ :run | 'worker completed' ].
background configureDaily: 'background' handler: 'collect'
 at: (Time hour: 0 minute: 0 second: 0) utcOffsetMinutes: 480 enabled: true.
[
 background start.
 deadline := DateAndTime now + 12 seconds.
 [
  items := background runsFor: 'background' limit: 1.
  (items isEmpty or: [ (items first at: 'status') ~= 'completed' ]) and: [ DateAndTime now < deadline ]
 ] whileTrue: [ (Delay forMilliseconds: 100) wait ].
 (items notEmpty and: [ (items first at: 'result') = 'worker completed' ])
  ifFalse: [ self error: 'Background worker did not execute the due task' ]
] ensure: [ background close ].
'GT scheduler contract passed'
