import AppKit
import AVKit
import Foundation

struct TVChannel: Hashable {
    let number: Int
    let band: String
    let frequency: Int
    var title: String { "Canal \(number)" }
    var subtitle: String { "\(band) - \(frequency) Hz" }
}

@MainActor
final class SianoController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let window: NSWindow
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Selecione um canal para assistir")
    private let detailLabel = NSTextField(labelWithString: "Siano TV Digital - ISDB-Tb Brasil")
    private let playerView = AVPlayerView()
    private let scanButton = NSButton(title: "Atualizar", target: nil, action: nil)
    private let stopButton = NSButton(title: "Parar", target: nil, action: nil)
    private var channels: [TVChannel] = []
    private var watchProcess: Process?
    private var currentOutputURL: URL?
    private var playbackTimer: Timer?

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
        window.title = "Siano TV Digital"
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
        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        videoPane.addSubview(playerView)
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
        statusLabel.stringValue = "Carregando canais brasileiros..."
        channels = runChannelsCommand(extended: false)
        if channels.isEmpty {
            channels = defaultChannels()
            detailLabel.stringValue = "Lista local usada; confira se /usr/local/bin/siano-tv esta instalado"
        } else {
            detailLabel.stringValue = "\(channels.count) canais mapeados"
        }
        tableView.reloadData()
    }

    @objc private func refreshChannels() {
        stopWatching()
        loadChannels()
        statusLabel.stringValue = "Lista atualizada"
    }

    @objc private func stopWatching() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        watchProcess?.terminate()
        watchProcess = nil
        playerView.player?.pause()
        playerView.player = nil
        statusLabel.stringValue = "Parado"
        detailLabel.stringValue = "Selecione um canal para assistir"
    }

    private func startWatching(_ channel: TVChannel) {
        stopWatching()
        let outputURL = captureURL(for: channel.number)
        currentOutputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let binary = findSianoTVBinary() else {
            statusLabel.stringValue = "siano-tv nao encontrado"
            detailLabel.stringValue = "Instale o pacote ou compile o projeto antes de assistir"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["watch-br", "\(channel.number)", "3600", outputURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        watchProcess = process

        do {
            try process.run()
            statusLabel.stringValue = "Sintonizando \(channel.title)..."
            detailLabel.stringValue = channel.subtitle
            schedulePlaybackProbe(outputURL)
        } catch {
            statusLabel.stringValue = "Falha ao iniciar recepcao"
            detailLabel.stringValue = error.localizedDescription
        }
    }

    private func schedulePlaybackProbe(_ outputURL: URL) {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return }
                let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 188 * 20 {
                    let player = AVPlayer(url: outputURL)
                    self.playerView.player = player
                    self.statusLabel.stringValue = "Reproduzindo"
                    self.detailLabel.stringValue = outputURL.path
                    player.play()
                    self.playbackTimer?.invalidate()
                    self.playbackTimer = nil
                } else {
                    self.statusLabel.stringValue = "Aguardando stream MPEG-TS..."
                    self.detailLabel.stringValue = "Se permanecer sem imagem, ajuste a posicao do dongle"
                }
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
        return TVChannel(number: number, band: bandParts.joined(separator: " "), frequency: frequency)
    }

    private func defaultChannels() -> [TVChannel] {
        (1...59).map { channel in
            TVChannel(number: channel, band: "Brasil", frequency: 0)
        }
    }

    private func captureURL(for channel: Int) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("SianoTV/canal-\(channel).ts")
    }

    private func findSianoTVBinary() -> String? {
        let candidates = [
            "/usr/local/bin/siano-tv",
            "\(FileManager.default.currentDirectoryPath)/build/siano-tv"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
