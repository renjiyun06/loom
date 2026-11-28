"Visual checks for the compact native conversation interface."
| report checks check ui card body editor text entry row values list bytes before attachments drafts more overflow label
  file name attachment caption lines longName tooltip draftImage draftFile space voice voiceView strip leftInset rightInset
  audio voiceMessage player duration |
report := Dictionary new. checks := OrderedCollection new.
check := [ :condition :name | condition ifFalse: [ self error: name ]. checks add: name ].
[
 before := LoomConversation orderedInputs size.
 ui := LMConversationUI new build.
 ui layoutComposerForWidth: 1120.
 check value: ((ui instVarNamed: 'composerPane') margin left - 38) abs < 1
  value: 'composer uses the wider centered reading width'.
 voice := LMVoiceComposer new.
 voiceView := voice buildFor: ui.
 voice instVarNamed: #phase put: #recording.
 voice refreshControls.
 voiceView forceLayout; forceLayout.
 strip := voiceView childNamed: #recordingStrip.
 leftInset := strip children first boundsInParent left.
 rightInset := strip width - strip children last boundsInParent right.
 check value: (leftInset > 0 and: [ (leftInset - rightInset) abs < 0.01 ])
  value: 'cancel and confirm have equal space to the recording strip border'.
 check value: (strip children third boundsInParent center x - (strip width / 2)) abs < 0.01
  value: 'pause is centered in the recording strip'.
 { strip children second. strip children fourth } do: [ :wave |
  leftInset := wave children first boundsInParent left.
  rightInset := wave width - wave children last boundsInParent right.
  check value: (leftInset >= 0 and: [ (leftInset - rightInset) abs < 0.01 ])
   value: 'the waveform fits inside its pane with equal padding' ].
 (ui instVarNamed: 'input') text: '输入测试'.
 ui resizeComposer.
 check value: ((ui instVarNamed: 'placeholderLabel') visibility class = BlVisibility gone class)
  value: 'placeholder disappears while typing'.
 (ui instVarNamed: 'input') text: ''.
 ui resizeComposer.
 check value: ((ui instVarNamed: 'placeholderLabel') visibility class = BlVisibility visible class)
  value: 'placeholder returns after clearing the input'.
 attachments := ui instVarNamed: 'attachmentDraftPane'.
 drafts := ui instVarNamed: 'draftAttachments'.
 check value: (attachments visibility class = BlVisibility gone class
  and: [ (ui instVarNamed: 'composerPane') children first == attachments ])
  value: 'the attachment strip is above the editor and takes no space when empty'.
 check value: ((ui instVarNamed: 'placeholderLabel') parent == (ui instVarNamed: 'input') parent)
  value: 'the placeholder moves down with the editor when files are added'.
 drafts addAll: #('D:\fixture\会议记录和需要补充说明的事项及后续安排.pdf'
  'D:\fixture\截图.PNG' 'D:\fixture\提纲.md' 'D:\fixture\附录.docx' 'D:\fixture\图表.xlsx' 'D:\fixture\笔记.txt').
 ui layoutComposerForWidth: 330.
 row := attachments children first.
 label := row children first children second text asString.
 check value: ((label includesSubstring: '…') and: [ label endsWith: '.pdf' ])
  value: 'long file names are shortened while keeping the extension'.
 more := row childNamed: #loomDraftAttachmentMore.
 check value: (attachments children size = 1 and: [
  more label asString = ('+', (drafts size - row children size + 1) asString) ])
  value: 'files that do not fit stay behind the correct plus count'.
 more viewModel action value.
 overflow := attachments childNamed: #loomDraftAttachmentList.
 check value: (overflow viewModel items asArray = (drafts allButFirst: row children size - 1) asArray
  and: [ overflow constraints vertical resizer size = (4 * 29) ])
  value: 'expanded overflow lists each hidden file in a bounded scroll area'.
 (attachments childNamed: #loomDraftAttachmentMore) viewModel action value.
 check value: attachments children size = 1 value: 'the plus button also collapses the overflow'.
 ui layoutComposerForWidth: 1120.
 check value: (attachments children first children size = drafts size)
  value: 'the attachment row shows more names when space is available'.
 draftFile := attachments children first children first.
 draftImage := attachments children first children second.
 attachments children first children first children last viewModel action value.
 check value: (drafts size = 5 and: [ drafts first endsWith: '截图.PNG' ])
  value: 'removing a file updates the draft and shifts the row'.
 drafts removeAll.
 ui renderDraftAttachments.
 check value: (attachments visibility class = BlVisibility gone class)
  value: 'clearing the draft removes the strip from the layout'.
 text := '第一行', String cr, '第二行', String cr, '第三行'.
 editor := LMChatStyle readOnly: text size: 14.
 editor hExact: 400; forceLayout.
 check value: editor height >= 72 value: 'native line boxes match compact CSS reading rhythm'.
 card := LMConversationMessageView new hExact: 1000; yourself.
 card descriptor: (Dictionary new at: 'id' put: 'short-bubble'; at: 'role' put: 'user';
  at: 'text' put: '你好'; at: 'createdAt' put: DateAndTime now asUTC asString; yourself).
 card forceLayout; forceLayout.
 body := card instVarNamed: 'body'.
 check value: body parent width < 120 value: 'short user bubbles hug their content'.
 check value: ((card instVarNamed: 'userMetadataLabel') text asString includes: $:)
  value: 'user metadata shows local message time'.
 audio := Dictionary new at: 'id' put: 'recording-fixture'; at: 'duration' put: 3;
  at: 'playing' put: false; at: 'playable' put: true; at: 'status' put: ''; yourself.
 voiceMessage := Dictionary new at: 'id' put: 'audio-bubble'; at: 'role' put: 'user';
  at: 'text' put: '嗯，好的。'; at: 'audio' put: audio; yourself.
 card descriptor: voiceMessage; forceLayout; forceLayout.
 body := card instVarNamed: 'body'.
 player := card childNamed: #voiceMessagePlay.
 duration := player children second.
 check value: (body parent width < 120 and: [ player boundsInParent right < body parent width ])
  value: 'a short transcript and its playback control fit a compact bubble'.
 check value: (player children size = 2 and: [ duration text asString = '0:03'
  and: [ player label asString = '播放原音' and: [ player states isEnabled ] ] ])
  value: 'the playback button holds both the icon and the recording duration'.
 card descriptor: (voiceMessage copy at: 'audio' put: (audio copy at: 'playing' put: true;
  at: 'duration' put: 6035; yourself); yourself); forceLayout; forceLayout.
 check value: (player children second == duration and: [ duration text asString = '100:35'
  and: [ duration boundsInParent right < player width and: [ player label asString = '停止播放' ] ] ])
  value: 'switching to stop retains the duration and fits longer recordings'.
 card descriptor: (voiceMessage copy at: 'text' put: ''; at: 'audio' put:
  (audio copy at: 'playable' put: false; at: 'status' put: '转录失败'; yourself); yourself); forceLayout.
 check value: (player states isDisabled and: [ body visibility class = BlVisibility gone class
  and: [ (card childNamed: #voiceMessageStatus) text asString = '转录失败'
   and: [ (card childNamed: #voiceMessageStatus) visibility class = BlVisibility visible class ] ] ])
  value: 'a missing original disables playback and an empty transcript leaves the error visible'.
 name := '0123456789abcdef0123456789abcdef.jpg'.
 file := Dictionary new at: 'name' put: name; at: 'relativePath' put: 'conversation.sqlite';
  at: 'image' put: true; yourself.
 entry := Dictionary new at: 'id' put: 'attachment-card'; at: 'role' put: 'user'; at: 'text' put: '你好';
  at: 'attachments' put: { file }; yourself.
 card descriptor: entry; forceLayout; forceLayout.
 attachment := card childNamed: #loomAttachmentCard.
 caption := attachment children second.
 check value: (caption children size = 1 and: [ caption children first text asString = name ])
  value: 'the attachment card shows the entire original name at normal width'.
 check value: ((card instVarNamed: 'body') parent width < 120 and: [ attachment states isEnabled ])
  value: 'the clickable attachment has its own width beside a compact text bubble'.
 check value: (draftImage children first id asSymbol = #loomImageAttachmentIcon
  and: [ draftImage children first id = attachment children first id ])
  value: 'a draft image with an uppercase extension and a sent image use the same icon'.
 space := ui presentationSpace.
 { draftImage. attachment } do: [ :each | space doStyle: each; doComputePropertiesFromRoot: each ].
 check value: (draftImage background paint color = attachment background paint color
  and: [ draftImage border paint color = attachment border paint color
   and: [ draftImage geometry cornerRadii = attachment geometry cornerRadii ] ])
  value: 'draft and sent attachments share the surface and corners'.
 card hExact: 240; forceLayout; forceLayout.
 lines := caption children collect: [ :child | child text asString ].
 check value: (lines size = 2 and: [ ('' join: lines) = name ])
  value: 'a narrow attachment card wraps an uninterrupted file name across two lines'.
 longName := (String new: 180 withAll: $a), '.pdf'.
 lines := card attachmentNameLines: longName at: 132.
 check value: (lines size = 2 and: [ (lines second beginsWith: '…') and: [ lines second endsWith: '.pdf' ] ])
  value: 'ellipsized attachment names preserve both the beginning and extension'.
 tooltip := card attachmentTooltipFor: longName.
 check value: ('' join: (tooltip children collect: [ :child | child text asString ])) = longName
  value: 'the attachment tooltip shows the complete original name'.
 card descriptor: (entry copy at: 'text' put: ''; yourself); forceLayout.
 check value: ((card instVarNamed: 'body') parent visibility class = BlVisibility gone class)
  value: 'attachment-only messages omit the empty text bubble'.
 card descriptor: (entry copy at: 'attachments' put: {
  file copy at: 'relativePath' put: 'absent-native-attachment-fixture.pdf'; yourself }; yourself); forceLayout.
 attachment := card childNamed: #loomAttachmentCard.
 check value: (attachment states isDisabled and: [
  attachment children second children last text asString = '附件找不到' ])
  value: 'a missing attachment has a disabled card and visible status'.
 file := file copy removeKey: 'image'; at: 'name' put: '项目提纲.pdf'; yourself.
 card descriptor: (entry copy at: 'attachments' put: { file }; yourself).
 attachment := card childNamed: #loomAttachmentCard.
 check value: (draftFile children first id asSymbol = #loomFileAttachmentIcon
  and: [ draftFile children first id = attachment children first id ])
  value: 'draft and older sent documents use the same file icon'.
 entry := Dictionary new at: 'id' put: 'visual-tool'; at: 'type' put: 'dynamicToolCall';
  at: 'tool' put: 'runtime_eval'; at: 'status' put: 'completed'; at: 'success' put: true;
  at: 'arguments' put: (Dictionary new at: 'code' put: '1 + 1'; yourself); at: 'durationMs' put: 12; yourself.
 row := LMConversationActivityView new controller: ui; hExact: 340; yourself.
 row descriptor: entry; forceLayout.
 check value: ((row instVarNamed: 'mark') allChildrenBreadthFirstSelect: [:child | child geometry isKindOf: BlSvgPath]) notEmpty
  value: 'completed tools use a vector status mark without missing font glyphs'.
 entry := entry copy at: 'executionPhase' put: 'started'; at: 'title' put: '正在执行 Smalltalk';
  at: 'status' put: 'inProgress'; at: 'text' put: '由 main 发起'; yourself.
 row descriptor: entry; forceLayout.
 check value: ((row instVarNamed: 'title') text asString = '执行 Smalltalk' and: [
  (row instVarNamed: 'tool') text asString = 'runtime_eval' and: [
  (row instVarNamed: 'duration') text asString = '执行中' and: [ (row instVarNamed: 'preview') visibility = BlVisibility gone ] ] ])
  value: 'running tools show the action, tool name and status in a single row'.
 row descriptor: (entry copy at: 'executionPhase' put: 'done'; at: 'title' put: '执行 Smalltalk';
  at: 'status' put: 'completed'; at: 'durationMs' put: 1250; yourself); forceLayout.
 check value: ((row instVarNamed: 'title') text asString = '执行 Smalltalk' and: [
  (row instVarNamed: 'duration') text asString = '1.25 秒' ]) value: 'elapsed seconds replace the running label in the same row'.
 entry := entry copy at: 'executionPhase' put: 'subrequest'; at: 'title' put: '核对回执 · 等待答复';
  at: 'status' put: 'pending'; at: 'text' put: '正在等待答复'; yourself.
 row descriptor: entry; forceLayout.
 check value: ((row instVarNamed: 'preview') visibility = BlVisibility visible)
  value: 'the waiting question is visible before completion'.
 entry := entry copy at: 'executionPhase' put: 'done'; at: 'title' put: '核对回执 · 已完成';
  at: 'status' put: 'completed'; at: 'text' put: '结果　已核对'; at: 'result' put: '已核对'; yourself.
 row descriptor: entry; forceLayout.
 check value: ((row instVarNamed: 'title') text asString = '核对回执' and: [
  (row instVarNamed: 'preview') visibility = BlVisibility gone and: [ (row instVarNamed: 'details') isNil ] ])
  value: 'a completed execution shows its action alone and drops the previous preview'.
 row toggle; showDetailMode: #result.
 check value: ((row instVarNamed: 'details') notNil and: [ row activityDetailText includesSubstring: '已核对' ])
  value: 'opening the result tab reveals the saved result'.
 row toggle.
 values := (LoomConversationWindow instVarNamed: 'lastPayload') at: 'activities'.
 values do: [ :value |
  row := LMConversationActivityView new controller: ui; hExact: 340; yourself.
  row descriptor: value; forceLayout ].
 checks add: 'every real activity entry binds and lays out successfully'.
 row := LMConversationActivityView new controller: ui; hExact: 340; yourself.
 ui bindActivityRow: row item: Dictionary new.
 check value: row children notEmpty value: 'malformed activity keeps a visible fallback without breaking list binding'.
 card := LMConversationMessageView new controller: ui; hExact: 1000; yourself.
 ui bindMessageRow: card item: Dictionary new.
 check value: card children notEmpty value: 'malformed message keeps a copyable fallback without breaking list binding'.
 list := (LoomConversationWindow instVarNamed: 'activity') childNamed: #scrollable.
 check value: (list instVarNamed: 'layoutOrScrollCounter') = 0
  value: 'live activity viewport has no interrupted layout transaction'.
 (((LoomConversationWindow instVarNamed: 'activityPane') visibility class = BlVisibility visible class) and: [
  (LoomConversationWindow instVarNamed: 'activityItems') notEmpty ]) ifTrue: [
  check value: list children notEmpty value: 'live activity viewport materializes visible rows' ].
 check value: (LoomConversation orderedInputs size = before) value: 'visual checks send no model request'.
 report at: 'ok' put: true; at: 'checks' put: checks asArray
] on: Error do: [ :error | report at: 'ok' put: false; at: 'error' put: error messageText; at: 'passed' put: checks asArray ].
report at: 'completedAt' put: DateAndTime now asString.
bytes := (STONJSON toString: report) utf8Encoded.
(ExperimentRoot / 'tests' / 'results' / 'native-chat-visual-validation.json')
 binaryWriteStreamDo: [ :out | out nextPutAll: bytes; truncate: bytes size ].
report
