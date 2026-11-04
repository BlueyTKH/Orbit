/*
 * NotchFlow (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import SwiftUI
import Observation
import Defaults

/// The half-finished files browsers leave in the Downloads folder, and the
/// finished file each one is going to turn into.
///
/// Every browser names its temporary file after the destination and adds an
/// extension: Chromium writes `archive.zip.crdownload`, Safari an
/// `archive.zip.download` bundle, Firefox `archive.zip.part`, and Opera --
/// Chromium underneath, but with its own name for this -- `archive.zip.opdownload`.
/// Stripping that extension therefore names the file the download is aiming at,
/// whichever browser produced it.
enum PartialDownload {
    /// Extensions that mark a file as still being written, lowercased.
    static let extensions: Set<String> = ["crdownload", "download", "opdownload", "part"]

    /// Whether `name` is a download in progress rather than a finished file.
    static func isInProgress(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The name `name` takes once the browser is finished with it.
    static func destination(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    /// Of the temporary files that have just vanished, the ones that finished —
    /// the rest were cancelled.
    ///
    /// A download is finished once its destination has been *written*, which is
    /// not the same as the destination being there. Two cases make the
    /// difference matter. Firefox creates the destination up front as an empty
    /// placeholder and writes the bytes to the `.part` file beside it, so mere
    /// existence proves nothing — holding data is the test, and only non-empty
    /// files get a stamp. And a download told to replace a file that is already
    /// there starts with a destination that holds data before a single byte
    /// arrives, so the stamp has to have *changed* since the temporary file
    /// appeared; otherwise cancelling one reads as a completion.
    ///
    /// - Parameters:
    ///   - stamps: modification dates of the non-empty files on disk now.
    ///   - stampsWhenStarted: the same, captured for each destination when its
    ///     temporary file first appeared. A missing entry means there was
    ///     nothing there, or nothing with anything in it.
    static func completed(
        among disappearedFiles: Set<String>,
        stamps: [String: Date],
        stampsWhenStarted: [String: Date]
    ) -> Set<String> {
        disappearedFiles.filter { name in
            let target = destination(of: name)
            guard let now = stamps[target] else { return false }
            guard let before = stampsWhenStarted[target] else { return true }
            // Later, not merely different. A destination that came out older
            // than it was when the download started was not written by it --
            // something restored or copied an earlier file over the name.
            return now > before
        }
    }
}


@Observable
@MainActor
class DownloadManager {
    static let shared = DownloadManager()
    
    private(set) var isDownloading: Bool = false
    private(set) var isDownloadCompleted: Bool = false

    /// Aggregate progress for the active downloads, from 0...1. `nil` means
    /// the browser has not exposed an expected total, so the UI must remain
    /// honestly indeterminate.
    private(set) var downloadProgress: Double?

    private var progressTimer: Timer?
    /// Changes whenever sampling starts or stops.
    ///
    /// Invalidating the timer does not reach work already queued on `queue`,
    /// nor the main-actor hop it ends with. Without this, a reading in flight
    /// when sampling stopped could land after the next download had started
    /// one, and seed that session's baseline with bytes measured before it --
    /// making the first rate it showed a fiction.
    private var progressSession = 0
    
    private let coordinator = DynamicIslandViewCoordinator.shared
    private var source: DispatchSourceFileSystemObject?
    /// Which run of monitoring a scan belongs to. A scan reads the folder on
    /// `queue` and delivers on the main actor, so one that was already reading
    /// when monitoring stopped lands *after* the state it describes has been
    /// cleared. If monitoring has restarted by then, that stale listing
    /// overwrites the fresh initial scan and the live activity comes up for a
    /// download that is no longer running -- with nothing to close it until
    /// the next directory event. Each scan carries the session it was started
    /// for and is dropped if that is no longer the current one.
    private var monitorSession = 0
    private let queue = DispatchQueue(label: "com.kayhsen.NotchFlow.downloads.monitor", qos: .utility)
    private var completionTimer: Timer?
    private var hasPerformedInitialScan: Bool = false
    private var previousInProgressFiles: Set<String> = []
    private var ignoredFiles: Set<String> = []
    /// Temporary files that have gone since the live activity appeared, held
    /// until nothing is being written any more. A download that lands while
    /// another is still going cannot be judged at the scan that sees it go —
    /// there is still active work — and dropping it there meant a run whose
    /// last download was cancelled closed the activity outright, with nothing
    /// shown for the ones that had finished.
    private var vanishedSinceActive: Set<String> = []
    /// What each in-flight download's destination looked like when its
    /// temporary file appeared, so a destination that was already on disk is
    /// not mistaken for one this download wrote.
    private var destinationStampsWhenStarted: [String: Date] = [:]
    
    private var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }
    
    init() {
        requestDownloadsPermissionIfNeeded()
        startMonitoringIfNeeded()
        
        Defaults.publisher(.enableDownloadListener)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.startMonitoringIfNeeded()
                }
            }
    }
    
    private func startMonitoringIfNeeded() {
        if Defaults[.enableDownloadListener] {
            startMonitoring()
        } else {
            stopMonitoring()
            // Not updateDownloadingState: stopMonitoring has already cleared
            // isDownloading, which is the flag that call checks before doing
            // anything, so switching the listener off mid-download left the
            // live activity on screen with nothing left to close it.
            closeDownloadViewImmediately()
        }
    }
    
    private func startMonitoring() {
        guard source == nil, let downloadsDirectory else { return }
        
        monitorSession &+= 1
        let session = monitorSession
        hasPerformedInitialScan = false
        previousInProgressFiles.removeAll()
        ignoredFiles.removeAll()
        vanishedSinceActive.removeAll()
        destinationStampsWhenStarted.removeAll()
        isDownloading = false

        let path = downloadsDirectory.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )
        
        src.setEventHandler { [weak self] in
            self?.scanDownloadsDirectory(session: session)
        }
        
        src.setCancelHandler {
            close(fd)
        }
        
        source = src
        // Queued before the source is resumed, and onto the same serial queue
        // the event handler runs on, so the baseline is always the first scan
        // to be delivered. Resuming first let a download that appeared during
        // the baseline's own directory read be processed as a watcher event
        // while `hasPerformedInitialScan` was still false -- which files it as
        // pre-existing and ignored, after which the late baseline could drop
        // it with nothing to notice it again until the next directory event.
        // It also keeps the directory read off the main actor.
        queue.async { [weak self] in
            self?.scanDownloadsDirectory(session: session)
        }
        src.resume()
    }
    
    private func stopMonitoring() {
        source?.cancel()
        source = nil
        
        monitorSession &+= 1
        hasPerformedInitialScan = false
        previousInProgressFiles.removeAll()
        ignoredFiles.removeAll()
        vanishedSinceActive.removeAll()
        destinationStampsWhenStarted.removeAll()
        isDownloading = false
        stopProgressSampling()
    }

    // MARK: - Download progress

    /// Sampled on a timer rather than off the directory's change events: those
    /// fire when the folder's listing changes, and a file merely growing does
    /// not always produce one. Two evenly spaced samples are also what makes
    /// the figure a rate rather than whatever arrived between two arbitrary
    /// moments.
    private func startProgressSampling() {
        guard progressTimer == nil else { return }

        progressSession &+= 1
        downloadProgress = nil

        let timer = Timer(timeInterval: Self.progressSampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
        sampleProgress()
    }

    private func stopProgressSampling() {
        progressSession &+= 1
        progressTimer?.invalidate()
        progressTimer = nil
        downloadProgress = nil
    }

    private func sampleProgress() {
        guard let downloadsDirectory else { return }

        let session = progressSession
        queue.async { [weak self] in
            guard let self else { return }
            let reading = Self.sample(in: downloadsDirectory, at: Date())
            Task { @MainActor in
                self.recordProgressSample(reading, session: session)
            }
        }
    }

    @MainActor
    private func recordProgressSample(_ reading: DownloadsSample, session: Int) {
        // A reading measured before the current sampling session began says
        // nothing about it.
        guard session == progressSession else { return }

        if let expectedBytes = reading.expectedBytes,
           expectedBytes > 0 {
            downloadProgress = min(max(Double(reading.bytes) / Double(expectedBytes), 0), 1)
        } else {
            downloadProgress = nil
        }
    }

    /// One reading of what the Downloads folder is holding.
    struct DownloadsSample: Equatable, Sendable {
        let bytes: Int64
        /// Sum of expected byte counts only when every active file exposes one.
        let expectedBytes: Int64?
        /// The in-progress names the total was taken across.
        let files: Set<String>
        let takenAt: Date

        init(
            bytes: Int64,
            expectedBytes: Int64? = nil,
            files: Set<String>,
            takenAt: Date
        ) {
            self.bytes = bytes
            self.expectedBytes = expectedBytes
            self.files = files
            self.takenAt = takenAt
        }

    }

    /// What the in-progress files hold right now.
    ///
    /// Allocated size rather than logical size: a browser that reserves the
    /// whole file up front reports its final size from the first moment, which
    /// would read as a download that finished instantly and then never moved.
    /// Blocks on disk grow as the bytes actually arrive.
    nonisolated static func bytesInProgress(in directory: URL) -> Int64 {
        sample(in: directory, at: Date()).bytes
    }

    nonisolated static func sample(in directory: URL, at now: Date) -> DownloadsSample {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey]
        ) else {
            return DownloadsSample(bytes: 0, expectedBytes: nil, files: [], takenAt: now)
        }

        var bytes: Int64 = 0
        var expectedBytes: Int64 = 0
        var allExpectedTotalsKnown = true
        var files: Set<String> = []
        for url in contents {
            let name = url.lastPathComponent
            guard PartialDownload.isInProgress(name) else { continue }
            files.insert(name)
            let measurement = progressMeasurement(of: url)
            bytes += measurement.downloaded
            if let expected = measurement.expected, expected > 0 {
                expectedBytes += expected
            } else {
                allExpectedTotalsKnown = false
            }
        }
        let aggregateExpected = !files.isEmpty && allExpectedTotalsKnown ? expectedBytes : nil
        return DownloadsSample(bytes: bytes, expectedBytes: aggregateExpected, files: files, takenAt: now)
    }

    private struct DownloadProgressMeasurement {
        let downloaded: Int64
        let expected: Int64?
    }

    /// Reads real progress metadata when the browser makes it available.
    /// Safari stores an expected total in its `.download` package. Some
    /// Chromium-family versions preallocate a sparse partial file; in that case
    /// logical size is the expected total while allocated blocks track bytes
    /// actually received. Ordinary growing files expose no total and remain
    /// indeterminate.
    nonisolated private static func progressMeasurement(of url: URL) -> DownloadProgressMeasurement {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .fileSizeKey])

        if values?.isDirectory == true {
            let downloaded = allocatedBytes(of: url)
            return DownloadProgressMeasurement(
                downloaded: downloaded,
                expected: safariExpectedByteCount(in: url, downloaded: downloaded)
            )
        }

        let logical = Int64(values?.fileSize ?? 0)
        let allocated = Int64(values?.fileAllocatedSize ?? values?.fileSize ?? 0)
        let sparseThreshold: Int64 = 64 * 1024
        if logical > allocated + sparseThreshold, allocated > 0 {
            return DownloadProgressMeasurement(downloaded: allocated, expected: logical)
        }

        return DownloadProgressMeasurement(downloaded: max(logical, 0), expected: nil)
    }

    nonisolated private static func safariExpectedByteCount(in bundle: URL, downloaded: Int64) -> Int64? {
        let candidateNames = ["Info.plist", "Download.plist", "Metadata.plist"]
        let expectedKeys = [
            "DownloadEntryProgressTotalToLoad",
            "NSURLSessionResumeBytesExpected",
            "NSURLSessionDownloadTaskResumeDataBytesExpected",
            "totalBytesExpectedToWrite",
            "bytesExpected",
            "expectedContentLength"
        ]

        for name in candidateNames {
            let url = bundle.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let expected = numericValue(forAnyKey: expectedKeys, in: plist),
                  expected > downloaded else { continue }
            return expected
        }
        return nil
    }

    nonisolated private static func numericValue(forAnyKey keys: [String], in value: Any) -> Int64? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let number = dictionary[key] as? NSNumber { return number.int64Value }
                if let string = dictionary[key] as? String, let number = Int64(string) { return number }
            }
            for child in dictionary.values {
                if let found = numericValue(forAnyKey: keys, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = numericValue(forAnyKey: keys, in: child) { return found }
            }
        }
        return nil
    }

    /// The bytes one in-progress download is holding.
    ///
    /// Safari's `.download` is a bundle rather than a file: the bytes land in a
    /// child file and the directory entry itself never grows, so measuring only
    /// the top level reports every Safari download as permanently stalled.
    /// Chromium, Firefox and Opera all write a plain partial file, which the
    /// first branch handles.
    nonisolated private static func allocatedBytes(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileAllocatedSizeKey, .fileSizeKey]

        func size(of item: URL) -> Int64 {
            let values = try? item.resourceValues(forKeys: keys)
            guard values?.isDirectory != true,
                  let bytes = values?.fileAllocatedSize ?? values?.fileSize
            else { return 0 }
            return Int64(bytes)
        }

        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return size(of: url)
        }

        guard let children = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys)
        ) else { return 0 }

        return children.reduce(into: Int64(0)) { total, child in
            guard let child = child as? URL else { return }
            total += size(of: child)
        }
    }

    /// A short interval makes a determinate bar visibly grow without tying UI
    /// redraws to the browser's irregular directory notifications.
    private static let progressSampleInterval: TimeInterval = 0.25
    
    /// Explicitly outside the main actor, because the directory source calls
    /// this from its own queue. Left isolated, the hop back was written as an
    /// unstructured `Task`, and one created from that queue never ran -- the
    /// listing was read and then silently dropped, so a download that appeared
    /// after launch was never noticed at all.
    nonisolated private func scanDownloadsDirectory(session: Int) {
        guard let downloadsDirectory = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        
        let inProgressFiles: Set<String>
        var stamps: [String: Date] = [:]

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: downloadsDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )

            inProgressFiles = Set(contents
                .map { $0.lastPathComponent }
                .filter { PartialDownload.isInProgress($0) }
            )

            for url in contents {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard (values?.fileSize ?? 0) > 0, let modified = values?.contentModificationDate else { continue }
                stamps[url.lastPathComponent] = modified
            }

        } catch {
            return
        }

        let resolvedStamps = stamps
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard session == self.monitorSession else { return }
                self.processDownloadFiles(inProgressFiles, stamps: resolvedStamps)
            }
        }
    }
    
    private func processDownloadFiles(_ inProgressFiles: Set<String>, stamps: [String: Date]) {

        if !hasPerformedInitialScan {
            hasPerformedInitialScan = true
            previousInProgressFiles = inProgressFiles
            ignoredFiles = inProgressFiles
            isDownloading = false
            return
        }

        let disappearedFiles = previousInProgressFiles.subtracting(inProgressFiles)
        let appearedFiles = inProgressFiles.subtracting(previousInProgressFiles)
        previousInProgressFiles = inProgressFiles

        // Captured the moment a download starts writing, and only then: taking
        // it later would record what this download had already put there.
        for name in appearedFiles {
            let target = PartialDownload.destination(of: name)
            destinationStampsWhenStarted[target] = stamps[target]
        }

        // Judged against the ignore list as it stands, before the expiry below.
        vanishedSinceActive.formUnion(disappearedFiles.subtracting(ignoredFiles))

        // A partial file present at launch is ignored by name, so a download
        // already running when the app starts does not claim an activity of its
        // own. Once that file is gone the name is free again — a later download
        // that happens to reuse it is a new download, and was otherwise ignored
        // for the life of the process.
        ignoredFiles.subtract(disappearedFiles)

        let activeFiles = inProgressFiles.subtracting(ignoredFiles)

        if !activeFiles.isEmpty {
            // Covers both a download appearing and one still writing: the state
            // update is a no-op once the live activity is already showing.
            updateDownloadingState(isActive: true)
            return
        }

        // completion logic
        guard isDownloading else {
            vanishedSinceActive.removeAll()
            destinationStampsWhenStarted.removeAll()
            return
        }

        // The completion animation owns the next couple of seconds, and a
        // directory event during them is likely rather than hypothetical --
        // the rename that finishes a download is itself one. Such a scan finds
        // nothing left to have completed, and would close the view mid-animation.
        guard !isDownloadCompleted else {
            vanishedSinceActive.removeAll()
            return
        }

        // Nothing is being written any more, so the downloads that were running
        // have either landed on their destination or been abandoned. Only a
        // finished one earns the completion animation; the destination never
        // appears as a download of its own, because a file that is not still
        // being written is not a partial download.
        let completedFiles = PartialDownload.completed(
            among: vanishedSinceActive,
            stamps: stamps,
            stampsWhenStarted: destinationStampsWhenStarted
        )
        vanishedSinceActive.removeAll()
        destinationStampsWhenStarted.removeAll()

        if completedFiles.isEmpty {
            closeDownloadViewImmediately()
        } else {
            updateDownloadingState(isActive: false)
        }
    }
    
#if DEBUG
    /// A manager that watches nothing, for tests.
    ///
    /// The scan-to-scan bookkeeping is the part worth testing and the part
    /// hardest to reach: it is driven by a directory watcher on the real
    /// Downloads folder, so exercising it any other way means creating files
    /// on the machine running the tests and racing the file system for them.
    /// This builds the same object with no watcher attached, so scans can be
    /// handed to it directly.
    init(monitoringDisabledForTesting: Bool) {
        precondition(monitoringDisabledForTesting)
    }

    /// One scan, in the shape the directory watcher delivers them.
    ///
    /// - Parameters:
    ///   - inProgressFiles: the partial-download files in the folder now.
    ///   - stamps: modification dates of the **non-empty** files in the folder
    ///     now. An empty file has no entry, which is how Firefox's placeholder
    ///     destination is told apart from one that has been written.
    func processScanForTesting(_ inProgressFiles: Set<String>, stamps: [String: Date] = [:]) {
        processDownloadFiles(inProgressFiles, stamps: stamps)
    }
#endif

    private func requestDownloadsPermissionIfNeeded() {
        guard let downloadsDirectory else { return }
        _ = try? FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)
    }
    
    private func updateDownloadingState(isActive: Bool) {
        completionTimer?.invalidate()
        completionTimer = nil
        
        if isActive {
            isDownloadCompleted = false
            
            // Outside the `!isDownloading` branch below: completion stops the
            // progress timer but holds `isDownloading` true for the two-second
            // completion animation, so a download starting inside that window
            // would never begin sampling and would show no progress for its
            // whole life. `startProgressSampling` no-ops while a timer is live,
            // so asking every time is safe.
            startProgressSampling()

            if !isDownloading {
                withAnimation(.smooth) {
                    isDownloading = true
                }
                coordinator.toggleExpandingView(
                    status: true,
                    type: .download,
                    value: 0
                )
            }
            
        } else {
            if isDownloading {
                stopProgressSampling()
                withAnimation(.smooth) {
                    isDownloadCompleted = true
                }
                
                completionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.closeDownloadView()
                    }
                }
            }
        }
    }
    
    private func closeDownloadView() {
        withAnimation(.smooth) {
            isDownloading = false
            isDownloadCompleted = false
        }
        
        coordinator.toggleExpandingView(
            status: false,
            type: .download,
            value: 0
        )
    }
    
    private func closeDownloadViewImmediately() {
        completionTimer?.invalidate()
        completionTimer = nil
        // Without this a cancelled download leaves the sampler scanning the
        // Downloads folder, and the next download inherits stale progress.
        stopProgressSampling()
        
        withAnimation(.smooth) {
            isDownloading = false
            isDownloadCompleted = false
        }
        
        coordinator.toggleExpandingView(
            status: false,
            type: .download,
            value: 0
        )
    }
}
