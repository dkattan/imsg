import Commander
import Foundation
import IMsgCore

enum SendAttachmentCommand {
  static let spec = CommandSpec(
    name: "send-attachment",
    abstract: "Send a file attachment via the IMCore bridge",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "file", names: [.long("file")], help: "absolute path to file"),
          .make(label: "replyTo", names: [.long("reply-to")], help: "guid of message to reply to"),
          .make(
            label: "transport", names: [.long("transport")],
            help: "transport to use: auto|dylib|applescript"),
        ],
        flags: [
          .make(label: "audio", names: [.long("audio")], help: "send as audio message")
        ]
      )
    ),
    usageExamples: [
      "imsg send-attachment --chat 'iMessage;-;+15551234567' --file ~/Pictures/me.jpg"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let file = values.option("file"), !file.isEmpty else {
      throw ParsedValuesError.missingOption("file")
    }
    let expanded = (file as NSString).expandingTildeInPath
    let transport = values.option("transport") ?? "auto"
    guard ["auto", "dylib", "applescript"].contains(transport) else {
      throw ParsedValuesError.invalidOption("transport")
    }
    let audio = values.flag("audio")
    if transport == "applescript" && audio {
      throw ParsedValuesError.invalidOption("audio")
    }
    let replyTo = values.option("replyTo") ?? ""
    if transport == "applescript" && !replyTo.isEmpty {
      throw ParsedValuesError.invalidOption("reply-to")
    }

    if transport != "applescript" {
      let staged = try MessageSender.stageAttachmentForMessagesApp(at: expanded)
      var params: [String: Any] = [
        "chatGuid": chat,
        "filePath": staged,
        "isAudioMessage": audio,
      ]
      if !replyTo.isEmpty {
        params["selectedMessageGuid"] = replyTo
      }
      do {
        let data = try await IMsgBridgeClient.shared.invoke(action: .sendAttachment, params: params)
        let guid = (data["messageGuid"] as? String) ?? ""
        BridgeOutput.emit(data, runtime: runtime, summary: "send-attachment: queued (guid=\(guid))")
        return
      } catch {
        if transport == "dylib" || audio || !replyTo.isEmpty {
          BridgeOutput.emitError(String(describing: error), runtime: runtime)
          throw BridgeOutput.EmittedError()
        }
      }
    }

    try MessageSender().send(
      MessageSendOptions(
        recipient: "",
        text: "",
        attachmentPath: expanded,
        chatGUID: chat
      ))
    BridgeOutput.emit(
      ["success": true, "transport": "applescript"],
      runtime: runtime,
      summary: "send-attachment: sent via AppleScript"
    )
  }
}


// MARK: - download-attachment

enum DownloadAttachmentCommand {
  static let spec = CommandSpec(
    name: "download-attachment",
    abstract: "Download a purged/undownloaded iMessage attachment via the IMCore bridge",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). Triggers an explicit
      CloudKit download of a purged attachment using IMFileTransferCenter's
      retrieveLocalFileURLForFileTransferWithGUID:options:completion: API.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "attachmentGuid", names: [.long("attachment-guid")], help: "attachment guid (e.g. at_0_3F664ACC-...)"),
          .make(label: "timeout", names: [.long("timeout")], help: "download timeout in seconds (default: 60)"),
        ]
      )
    ),
    usageExamples: [
      "imsg download-attachment --attachment-guid 'at_0_3F664ACC-1234-5678-9ABC-DEF012345678'"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let guid = values.option("attachmentGuid"), !guid.isEmpty else {
      throw ParsedValuesError.missingOption("attachmentGuid")
    }
    let timeoutStr = values.option("timeout") ?? "60"
    let timeout = Int(timeoutStr) ?? 60
    let params: [String: Any] = [
      "attachmentGuid": guid,
      "timeout": timeout,
    ]
    let data = try await IMsgBridgeClient.shared.invoke(
      action: .downloadPurgedAttachment,
      params: params,
      timeout: TimeInterval(timeout)
    )
    let filename = (data["filename"] as? String) ?? ""
    BridgeOutput.emit(
      data,
      runtime: runtime,
      summary: "download-attachment: \(filename.isEmpty ? "no path" : filename)"
    )
  }
}
