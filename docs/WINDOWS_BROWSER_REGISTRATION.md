# Windows document-start registration

The generated Windows browser check reproduced a missing document-start script
on the first navigation. The pinned plugin's `addUserScript` handler returns
success after queuing registration, before its native completion callback runs.
That acknowledgement is insufficient for Ownsemble's browser contract.

The Windows adapter now awaits `Page.addScriptToEvaluateOnNewDocument` through
the existing in-process protocol bridge and requires its registration identifier.
Missing, malformed, failed or timed-out acknowledgements stop the operation with
`browser_document_start_failed`. No external debugging endpoint, profile access,
credential export or script-content logging is introduced.

The [protocol definition](https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-addScriptToEvaluateOnNewDocument)
specifies the registration identifier. Microsoft's
[WebView2 scripting documentation](https://learn.microsoft.com/en-us/microsoft-edge/hosting/webview2/gettingstarted)
also explains that ordered scripting operations must wait for callbacks.

## Validation

Before implementation, the actual generated Windows browser report recorded
`document_start_script=false` and `passed=false`. New unit tests then failed
because the acknowledged-registration helper did not exist. After implementation,
the delayed acknowledgement, JSON reply and malformed-reply tests passed.

The rebuilt Windows Release passed the actual generated native browser check:
document-start execution, native muting, hidden windows, trusted input, cached
request observation and independent scanner progress. The Windows analyzer is
clean and all 207 Flutter tests pass at this checkpoint.

A separate authorized normal Windows run retained 2,633 catalog records. A cached
selection started in 1,113 ms. During 45 samples under a concurrent full scan, the
clock advanced 43,990 ms across 44 sampling intervals, with940–1050ms steps, no
stationary samples and no reported buffering. These measurements establish that
sampled playback progressed; they do not independently establish audible quality
or resolve the recurring pauses observed through WSLg.

The full provider scan remains partial. Windows progressed beyond the previous
115-row boundary, but a later bounded slice stopped at a quiet boundary after 895
records. Existing catalog records were preserved. Native Ubuntu audio acceptance
and complete provider coverage remain separate gates.
