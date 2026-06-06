import AppKit
import AVKit
import Foundation

struct TVChannel: Codable, Hashable, Sendable {
    let number: Int
    let band: String
    let frequency: Int
    var name: String?
    var rfLocked: Bool?
    var demodLocked: Bool?
    var scanStatus: String?
    var title: String {
        guard let name, !name.isEmpty else { return "Canal \(number)" }
        return name
    }
    var subtitle: String {
        let prefix = (number > 0 && name != nil && name?.isEmpty == false) ? "Canal \(number) - " : ""
        let base = "\(prefix)\(band) - \(frequency) Hz"
        guard let rfLocked, let demodLocked else { return base }
        if demodLocked { return "\(base) - pronto para imagem" }
        if rfLocked { return "\(base) - portadora sem demod" }
        return "\(base) - sem lock"
    }
}

@MainActor
final class SianoController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let minimumPreviewBytes = 96 * 1024
    private let window: NSWindow
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Selecione um canal para assistir")
    private let detailLabel = NSTextField(labelWithString: "Visionem DTV - ISDB-Tb Brasil")
    private let playerView = AVPlayerView()
    private let frameView = NSImageView()
    private let scanButton = NSButton(title: "Atualizar", target: nil, action: nil)
    private let stopButton = NSButton(title: "Parar", target: nil, action: nil)
    private var channels: [TVChannel] = []
    private var scanProcess: Process?
    private var watchProcess: Process?
    private var watchOutputPipe: Pipe?
    private var currentOutputURL: URL?
    private var currentChannelNumber: Int?
    private var playbackTimer: Timer?
    private var frameTimer: Timer?
    private var isExtractingFrame = false
    private var fallbackDumpStarted = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        loadChannels()
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func configureWindow() {
        window.title = "Visionem DTV"
        window.minSize = NSSize(width: 860, height: 520)

        let root = NSSplitView()
        root.isVertical = true
        root.dividerStyle = .thin
        root.translatesAutoresizingMaskIntoConstraints = false

        let videoPane = NSView()
        let sidebar = NSView()
        root.addArrangedSubview(videoPane)
        root.addArrangedSubview(sidebar)

        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false
        frameView.imageScaling = .scaleProportionallyUpOrDown
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.black.cgColor
        frameView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        videoPane.addSubview(playerView)
        videoPane.addSubview(frameView)
        videoPane.addSubview(statusLabel)
        videoPane.addSubview(detailLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.rowHeight = 54
        tableView.delegate = self
        tableView.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel"))
        column.resizingMask = .autoresizingMask
        column.width = 320
        column.minWidth = 260
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        scanButton.target = self
        scanButton.action = #selector(refreshChannels)
        stopButton.target = self
        stopButton.action = #selector(stopWatching)

        let controls = NSStackView(views: [scanButton, stopButton])
        controls.orientation = .horizontal
        controls.distribution = .fillEqually
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Canais")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(title)
        sidebar.addSubview(controls)
        sidebar.addSubview(scrollView)

        window.contentView = NSView()
        window.contentView?.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),

            videoPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 620),
            sidebar.widthAnchor.constraint(equalToConstant: 320),

            playerView.leadingAnchor.constraint(equalTo: videoPane.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: videoPane.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: videoPane.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: videoPane.bottomAnchor),

            frameView.leadingAnchor.constraint(equalTo: videoPane.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: videoPane.trailingAnchor),
            frameView.topAnchor.constraint(equalTo: videoPane.topAnchor),
            frameView.bottomAnchor.constraint(equalTo: videoPane.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: videoPane.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: videoPane.centerYAnchor, constant: -16),
            detailLabel.centerXAnchor.constraint(equalTo: videoPane.centerXAnchor),
            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),

            title.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),

            controls.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            controls.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),

            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
    }

    private func loadChannels() {
        statusLabel.stringValue = "Carregando canais salvos..."
        channels = loadSavedChannels()
        tableView.reloadData()
        if channels.isEmpty {
            statusLabel.stringValue = "Nenhum canal salvo"
            detailLabel.stringValue = "Primeira execucao; iniciando varredura brasileira"
            startScan()
        } else {
            detailLabel.stringValue = "\(channels.count) canais salvos"
        }
    }

    @objc private func refreshChannels() {
        stopWatching()
        startScan()
    }

    @objc private func stopWatching() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        isExtractingFrame = false
        scanProcess?.terminate()
        scanProcess = nil
        watchProcess?.terminate()
        watchProcess = nil
        watchOutputPipe?.fileHandleForReading.readabilityHandler = nil
        watchOutputPipe = nil
        currentOutputURL = nil
        currentChannelNumber = nil
        fallbackDumpStarted = false
        playerView.player?.pause()
        playerView.player = nil
        frameView.image = nil
        statusLabel.isHidden = false
        detailLabel.isHidden = false
        statusLabel.stringValue = "Parado"
        detailLabel.stringValue = "Selecione um canal para assistir"
    }

    private func startScan() {
        guard let binary = findSianoTVBinary() else {
            statusLabel.stringValue = "siano-tv nao encontrado"
            detailLabel.stringValue = "Instale o pacote antes de atualizar"
            return
        }

        channels = channels.map {
            TVChannel(number: $0.number, band: $0.band, frequency: $0.frequency, name: $0.name, rfLocked: nil, demodLocked: nil, scanStatus: "aguardando")
        }
        tableView.reloadData()
        scanButton.isEnabled = false
        statusLabel.stringValue = "Atualizando canais..."
        detailLabel.stringValue = "Executando scan-br; isso pode levar cerca de 1 minuto"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["scan-br"]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                DispatchQueue.main.async {
                    self.scanProcess = process
                }
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let scanned = text
                    .split(separator: "\n")
                    .compactMap { parseScanLine(String($0)) }
                    .filter { $0.rfLocked == true || $0.demodLocked == true }
                let fallbackName = scanned.isEmpty ? Self.detectCurrentStreamName(binary: binary) : nil
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.channels.removeAll { channel in
                        channel.name == nil && channel.rfLocked != true && channel.demodLocked != true
                    }
                    for channel in scanned {
                        self.applyScanResult(channel)
                    }
                    if scanned.isEmpty, self.isMDTVPresent(binary: binary) {
                        self.applyScanResult(Self.currentStreamPlaceholder(name: fallbackName ?? "Fluxo atual"))
                    }
                    self.scanButton.isEnabled = true
                    self.persistChannels()
                    self.statusLabel.stringValue = "Atualizacao concluida"
                    let ready = self.channels.filter { $0.demodLocked == true }.count
                    let carriers = self.channels.filter { $0.rfLocked == true }.count
                    self.detailLabel.stringValue = "\(ready) canais com demod, \(carriers) com portadora"
                }
            } catch {
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.scanButton.isEnabled = true
                    self.statusLabel.stringValue = "Falha ao atualizar"
                    self.detailLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func applyScanResult(_ scanned: TVChannel) {
        var updated = scanned
        if let index = channels.firstIndex(where: { $0.number == scanned.number }) {
            updated.name = channels[index].name
            channels[index] = updated
        } else {
            channels.append(updated)
            channels.sort { $0.number < $1.number }
        }
        tableView.reloadData()
        persistChannels()
        statusLabel.stringValue = "Canal \(updated.number): \(updated.scanStatus ?? "testado")"
        detailLabel.stringValue = updated.subtitle
    }

    private func startWatching(_ channel: TVChannel) {
        stopWatching()
        let outputURL = captureURL(for: channel.number)
        currentOutputURL = outputURL
        currentChannelNumber = channel.number
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let binary = findSianoTVBinary() else {
            statusLabel.stringValue = "siano-tv nao encontrado"
            detailLabel.stringValue = "Instale o pacote ou compile o projeto antes de assistir"
            return
        }

        fallbackDumpStarted = false
        if channel.number == 0 || shouldStartWithDump(binary: binary) {
            fallbackDumpStarted = true
            runWatchProcess(binary: binary, arguments: ["dump-ts", "3600", outputURL.path], outputURL: outputURL, channel: channel, isFallback: true)
        } else {
            runWatchProcess(binary: binary, arguments: ["watch-br", "\(channel.number)", "3600", outputURL.path], outputURL: outputURL, channel: channel, isFallback: false)
        }
    }

    private func shouldStartWithDump(binary: String) -> Bool {
        let version = runShortCommand(binary: binary, arguments: ["version"])
        if version.exitCode == 0 {
            return false
        }
        return isMDTVPresent(binary: binary)
    }

    private func isMDTVPresent(binary: String) -> Bool {
        let state = runShortCommand(binary: binary, arguments: ["usb-state"])
        return state.output.contains("mdtv=1")
    }

    private func runShortCommand(binary: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func runWatchProcess(binary: String, arguments: [String], outputURL: URL, channel: TVChannel, isFallback: Bool) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        watchProcess = process
        watchOutputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.applyWatchOutput(text)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.watchProcess === process else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size < 188 * 20, !isFallback, !self.fallbackDumpStarted {
                    self.fallbackDumpStarted = true
                    self.statusLabel.stringValue = "Recepcao ativa; usando fallback TS"
                    self.detailLabel.stringValue = "Lendo fluxo MPEG-TS ja aberto pelo firmware"
                    self.runWatchProcess(binary: binary, arguments: ["dump-ts", "3600", outputURL.path], outputURL: outputURL, channel: channel, isFallback: true)
                    return
                }
                if size < 188 * 20 {
                    self.statusLabel.stringValue = "Sem stream MPEG-TS"
                    self.detailLabel.stringValue = "Ajuste a posicao do dongle e tente novamente"
                }
            }
        }

        do {
            try process.run()
            statusLabel.stringValue = isFallback ? "Lendo stream MPEG-TS..." : "Sintonizando \(channel.title)..."
            detailLabel.stringValue = isFallback ? outputURL.path : channel.subtitle
            schedulePlaybackProbe(outputURL, channelNumber: channel.number)
        } catch {
            statusLabel.stringValue = isFallback ? "Falha no fallback TS" : "Falha ao iniciar recepcao"
            detailLabel.stringValue = error.localizedDescription
        }
    }

    private func applyWatchOutput(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init)
        guard let line = lines.last else { return }
        if line.contains("bytes=") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        } else if line.contains("demod lock") {
            statusLabel.stringValue = "Sinal digital travado"
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        } else if line.contains("final bytes") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        } else if line.contains("failed") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        }
    }

    private func schedulePlaybackProbe(_ outputURL: URL, channelNumber: Int) {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return }
                let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > Self.minimumPreviewBytes {
                    self.updateChannelNameFromTransportStream(outputURL, channelNumber: channelNumber)
                    self.startFramePreview(outputURL)
                    self.statusLabel.stringValue = "Recebendo transmissao"
                    self.detailLabel.stringValue = outputURL.path
                    self.playbackTimer?.invalidate()
                    self.playbackTimer = nil
                } else {
                    self.statusLabel.isHidden = false
                    self.detailLabel.isHidden = false
                    self.statusLabel.stringValue = "Aguardando video..."
                    self.detailLabel.stringValue = "Recebendo TS; aguardando pacotes de video suficientes"
                }
            }
        }
    }

    private func startFramePreview(_ outputURL: URL) {
        frameTimer?.invalidate()
        renderFrame(from: outputURL)
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.renderFrame(from: outputURL)
            }
        }
    }

    private func renderFrame(from outputURL: URL) {
        guard !isExtractingFrame else { return }
        isExtractingFrame = true
        let frameURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionem-dtv-frame-\(UUID().uuidString).jpg")
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? FileManager.default.removeItem(at: frameURL)
                DispatchQueue.main.async {
                    self.isExtractingFrame = false
                }
            }
            guard let ffmpeg = Self.findExecutable(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]) else {
                DispatchQueue.main.async {
                    self.detailLabel.stringValue = "ffmpeg nao encontrado para preview interno"
                }
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", outputURL.path,
                "-map", "0:v:0",
                "-an",
                "-frames:v", "1",
                "-q:v", "3",
                frameURL.path
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return
            }
            guard process.terminationStatus == 0, let image = NSImage(contentsOf: frameURL) else {
                return
            }
            DispatchQueue.main.async {
                self.frameView.image = image
                self.statusLabel.isHidden = true
                self.detailLabel.isHidden = true
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        channels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ChannelCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        cell.subviews.forEach { $0.removeFromSuperview() }

        let channel = channels[row]
        let title = NSTextField(labelWithString: channel.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        if channel.demodLocked == true {
            title.textColor = .systemGreen
        } else if channel.rfLocked == true {
            title.textColor = .systemOrange
        } else if channel.rfLocked == false {
            title.textColor = .secondaryLabelColor
        }
        let subtitle = NSTextField(labelWithString: channel.subtitle)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 && row < channels.count else { return }
        startWatching(channels[row])
    }

    private func runChannelsCommand(extended: Bool) -> [TVChannel] {
        guard let binary = findSianoTVBinary() else { return [] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [extended ? "channels-br-extended" : "channels-br"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap(parseChannelLine)
    }

    private func parseChannelLine(_ line: Substring) -> TVChannel? {
        let text = String(line)
        guard text.contains("canal="), text.contains("freq=") else { return nil }
        let parts = text.split(separator: " ")
        var number: Int?
        var bandParts: [String] = []
        var frequency: Int?
        var readingBand = false
        for rawPart in parts {
            let part = String(rawPart)
            if part.hasPrefix("canal=") {
                number = Int(part.dropFirst("canal=".count))
                readingBand = false
            } else if part.hasPrefix("faixa=") {
                bandParts = [String(part.dropFirst("faixa=".count))]
                readingBand = true
            } else if part.hasPrefix("freq=") {
                frequency = Int(part.dropFirst("freq=".count))
                readingBand = false
            } else if readingBand {
                bandParts.append(part)
            }
        }
        guard let number, let frequency else { return nil }
        return TVChannel(number: number, band: bandParts.joined(separator: " "), frequency: frequency, name: nil, rfLocked: nil, demodLocked: nil, scanStatus: nil)
    }

    private func captureURL(for channel: Int) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("SianoTV/canal-\(channel).ts")
    }

    private static func currentStreamPlaceholder(name: String) -> TVChannel {
        TVChannel(
            number: 0,
            band: "fluxo MPEG-TS atual",
            frequency: 0,
            name: name,
            rfLocked: true,
            demodLocked: true,
            scanStatus: "stream_atual"
        )
    }

    private func findSianoTVBinary() -> String? {
        let candidates = [
            "/usr/local/bin/siano-tv",
            "\(FileManager.default.currentDirectoryPath)/build/siano-tv"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func channelsStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Visionem DTV/channels-br.json")
    }

    private func legacyChannelsStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Siano TV Digital/channels-br.json")
    }

    private func visionemChannelsStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Visionem/channels-br.json")
    }

    private func loadSavedChannels() -> [TVChannel] {
        guard let url = channelsStoreURL(),
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([TVChannel].self, from: data) else {
            return migrateLegacyChannels()
        }
        return saved.sorted { $0.number < $1.number }
    }

    private func migrateLegacyChannels() -> [TVChannel] {
        let candidateURLs = [visionemChannelsStoreURL(), legacyChannelsStoreURL()].compactMap { $0 }
        guard let sourceURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: sourceURL),
              let saved = try? JSONDecoder().decode([TVChannel].self, from: data) else {
            return []
        }
        channels = saved.sorted { $0.number < $1.number }
        persistChannels()
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
        return channels
    }

    private func persistChannels() {
        guard let url = channelsStoreURL() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(channels.sorted { $0.number < $1.number })
            try data.write(to: url, options: [.atomic])
        } catch {
            detailLabel.stringValue = "Nao foi possivel salvar canais: \(error.localizedDescription)"
        }
    }

    private func updateChannelNameFromTransportStream(_ url: URL, channelNumber: Int) {
        DispatchQueue.global(qos: .utility).async {
            guard let name = Self.detectServiceName(in: url) else { return }
            DispatchQueue.main.async {
                guard let index = self.channels.firstIndex(where: { $0.number == channelNumber }) else { return }
                if self.channels[index].name != name {
                    self.channels[index].name = name
                    self.tableView.reloadData()
                    self.persistChannels()
                }
            }
        }
    }

    nonisolated private static func detectServiceName(in url: URL) -> String? {
        guard let ffprobe = findExecutable(["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]) else {
            return nil
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error",
            "-show_entries", "program_tags=service_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.lowercased() != "unknown" }
    }

    nonisolated private static func findExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func detectCurrentStreamName(binary: String) -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("siano-tv-current-stream-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["dump-ts", "4", outputURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 188 * 20 else { return nil }
        return detectServiceName(in: outputURL)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: SianoController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = SianoController()
        controller?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

func parseScanLine(_ text: String) -> TVChannel? {
    guard text.contains("canal="), text.contains("freq="), text.contains("rf="), text.contains("demod=") else { return nil }
    let parts = text.split(separator: " ")
    var number: Int?
    var bandParts: [String] = []
    var frequency: Int?
    var rf: Bool?
    var demod: Bool?
    var status: String?
    var readingBand = false
    for rawPart in parts {
        let part = String(rawPart)
        if part.hasPrefix("canal=") {
            number = Int(part.dropFirst("canal=".count))
            readingBand = false
        } else if part.hasPrefix("faixa=") {
            bandParts = [String(part.dropFirst("faixa=".count))]
            readingBand = true
        } else if part.hasPrefix("freq=") {
            frequency = Int(part.dropFirst("freq=".count))
            readingBand = false
        } else if part.hasPrefix("rf=") {
            rf = part.hasSuffix("1")
            readingBand = false
        } else if part.hasPrefix("demod=") {
            demod = part.hasSuffix("1")
            readingBand = false
        } else if part.hasPrefix("status=") {
            status = String(part.dropFirst("status=".count))
            readingBand = false
        } else if readingBand {
            bandParts.append(part)
        }
    }
    guard let number, let frequency else { return nil }
    return TVChannel(number: number, band: bandParts.joined(separator: " "), frequency: frequency, name: nil, rfLocked: rf, demodLocked: demod, scanStatus: status)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
