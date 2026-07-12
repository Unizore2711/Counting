import SwiftUI
import Combine
import PhotosUI
import Speech
import AVFoundation

// --- 1. 数据模型与全局状态 ---
struct FocusItem: Identifiable, Codable { var id = UUID(); var name: String }
struct Folder: Identifiable, Codable { var id = UUID(); var name: String; var items: [FocusItem] = [] }
struct EmotionTag: Identifiable, Codable { var id = UUID(); var name: String; var hex: String }

struct SessionLog: Identifiable, Codable {
    var id = UUID(); var itemName: String; var duration: Int; var emotion: String; var date: Date = Date()
    var note: String = ""; var imageData: Data? = nil; var voiceRecordPath: String?
}

struct AppDataBackup: Codable {
    var folders: [Folder]; var logs: [SessionLog]; var emotionTags: [EmotionTag]
    var trash: [String]; var pinnedMission: String
    var archive: [String]? // 新增：归档区（兼容旧数据设计为可选类型）
}

class AppDataStore: ObservableObject {
    @Published var folders: [Folder] = [Folder(name: "默认领域")]
    @Published var logs: [SessionLog] = []
    @Published var emotionTags: [EmotionTag] = [
        EmotionTag(name: "顺流", hex: "32C1B8"), EmotionTag(name: "受阻", hex: "A05A42"), EmotionTag(name: "启发", hex: "F2C94C")
    ]
    @Published var trash: [String] = []
    @Published var archive: [String] = [] // 新增：掘金归档区
    @Published var pinnedMission: String = "在时间的长河中，探寻并丈量属于自己的航道。"
    
    @Published var isTimerRunning = false
    @Published var activeFocusItem: String? = nil
    @Published var activeTimeElapsed = 0
    @Published var sessionThoughts: [String] = []
    
    private var timerSubscription: AnyCancellable?
    
    var dominantEmotionTag: EmotionTag {
        let stats = Dictionary(grouping: logs, by: { $0.emotion }).mapValues { $0.reduce(0) { $0 + max($1.duration, 60) } }
        if let maxEmotion = stats.max(by: { $0.value < $1.value })?.key, let tag = emotionTags.first(where: { $0.name == maxEmotion }) { return tag }
        return emotionTags.first ?? EmotionTag(name: "探索中", hex: "32C1B8")
    }
    
    init() { load() }
    
    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ZenFlowData.json")
    }
    
    func save() {
        let backup = AppDataBackup(folders: folders, logs: logs, emotionTags: emotionTags, trash: trash, pinnedMission: pinnedMission, archive: archive)
        if let data = try? JSONEncoder().encode(backup) { try? data.write(to: fileURL, options: .atomic) }
    }
    
    func load() {
        if let data = try? Data(contentsOf: fileURL), let backup = try? JSONDecoder().decode(AppDataBackup.self, from: data) {
            self.folders = backup.folders; self.logs = backup.logs; self.emotionTags = backup.emotionTags
            self.trash = backup.trash; self.pinnedMission = backup.pinnedMission
            self.archive = backup.archive ?? [] // 兼容旧版本数据加载
        }
    }
    
    func startTimer(for itemName: String) {
        if activeFocusItem != itemName { activeTimeElapsed = 0; sessionThoughts.removeAll() }
        activeFocusItem = itemName; isTimerRunning = true
        timerSubscription = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.activeTimeElapsed += 1 }
    }
    func pauseTimer() { isTimerRunning = false; timerSubscription?.cancel() }
    func resetTimer() { pauseTimer(); activeTimeElapsed = 0; activeFocusItem = nil; sessionThoughts.removeAll() }
    
    func generateCSVExport() -> String {
        var csvString = "记录时间,领域/技能,投入时长(秒),情绪体感,思想碎片\n"
        for log in logs {
            let dateStr = log.date.formatted(date: .numeric, time: .shortened).replacingOccurrences(of: ",", with: " ")
            let noteStr = log.note.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ",", with: "，")
            csvString.append("\(dateStr),\(log.itemName),\(log.duration),\(log.emotion),\(noteStr)\n")
        }
        return csvString
    }
}

// --- 语音识别引擎 ---
class SpeechManager: ObservableObject {
    @Published var transcript = ""; @Published var isRecording = false
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?; private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    func toggleRecording() { if isRecording { stopRecording() } else { startRecording() } }
    
    private func startRecording() {
        transcript = ""
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized { do { try self.beginAudioEngine() } catch { self.transcript = "录音引擎启动失败" } }
                else { self.transcript = "请在系统设置中开启语音识别权限" }
            }
        }
    }
    
    private func beginAudioEngine() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result { DispatchQueue.main.async { self.transcript = result.bestTranscription.formattedString } }
            if error != nil || (result?.isFinal ?? false) { self.stopRecording() }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in self.recognitionRequest?.append(buffer) }
        audioEngine.prepare(); try audioEngine.start(); isRecording = true
    }
    
    func stopRecording() { audioEngine.stop(); audioEngine.inputNode.removeTap(onBus: 0); recognitionRequest?.endAudio(); recognitionTask?.cancel(); isRecording = false }
}

// --- 2. 主界面 ---
struct ContentView: View {
    @StateObject private var store = AppDataStore()
    @State private var selection: String?
    @Environment(\.scenePhase) var scenePhase
    @State private var isBreathing = false
    @State private var showRenameAlert = false; @State private var renameTitle = ""; @State private var renameInput = ""; @State private var renameAction: (() -> Void)? = nil
    @State private var showManualLog = false; @State private var showMomentCapture = false
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // 置顶人生使命与气场
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("🎯 置顶人生使命").font(.caption).bold().opacity(0.8); Spacer()
                        Button(action: { triggerRename(title: "重塑人生使命", current: store.pinnedMission) { store.pinnedMission = $0 } }) { Image(systemName: "square.and.pencil").font(.caption) }
                    }
                    Text(store.pinnedMission).font(.subheadline).bold().fixedSize(horizontal: false, vertical: true)
                    HStack { Text("主导生命状态：\(store.dominantEmotionTag.name)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.3)).cornerRadius(4) }.padding(.top, 4)
                }
                .padding().background(Color(hex: store.dominantEmotionTag.hex).opacity(0.85)).foregroundColor(.white).cornerRadius(12).padding().shadow(color: Color(hex: store.dominantEmotionTag.hex).opacity(0.3), radius: 8, x: 0, y: 4)
                
                List(selection: $selection) {
                    Section("主控") {
                        Button(action: { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); selection = "QUICK_START"; store.startTimer(for: "未分类探索") }) { Label("快速专注", systemImage: "bolt.fill").foregroundColor(Color(hex: "32C1B8")) }
                        Button(action: { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); showMomentCapture = true }) { Label("捕捉瞬间", systemImage: "sparkles").foregroundColor(.orange).bold() }
                        NavigationLink(value: "CALENDAR") { Label("觉察日历", systemImage: "calendar") }
                        NavigationLink(value: "MISSION_INSIGHT") { Label("使命洞察", systemImage: "chart.bar.xaxis") }
                        Button(action: { showManualLog = true }) { Label("手动补记", systemImage: "clock.badge.checkmark").foregroundColor(.primary) }
                    }
                    Section("状态自定义") {
                        ForEach(store.emotionTags.indices, id: \.self) { eIdx in
                            HStack {
                                ColorPicker("", selection: Binding(get: { Color(hex: store.emotionTags[eIdx].hex) }, set: { store.emotionTags[eIdx].hex = $0.toHex() })).labelsHidden(); Text(store.emotionTags[eIdx].name); Spacer()
                                Button(action: { triggerRename(title: "修改状态名", current: store.emotionTags[eIdx].name) { store.emotionTags[eIdx].name = $0 } }) { Image(systemName: "pencil").foregroundColor(.gray).opacity(0.6) }.buttonStyle(.borderless)
                            }.swipeActions(edge: .trailing) { Button("删除", role: .destructive) { store.emotionTags.remove(at: eIdx); store.save() } }
                        }
                        Button("+ 添加新状态") { store.emotionTags.append(EmotionTag(name: "新状态", hex: "888888")); store.save() }
                    }
                    Section("我的路") {
                        ForEach(store.folders.indices, id: \.self) { fIdx in
                            DisclosureGroup {
                                ForEach(store.folders[fIdx].items.indices, id: \.self) { iIdx in
                                    HStack { Text(store.folders[fIdx].items[iIdx].name); Spacer(); Image(systemName: "play.circle.fill").foregroundColor(Color(hex: "32C1B8")).font(.title3) }
                                    .contentShape(Rectangle())
                                    .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); let itemName = store.folders[fIdx].items[iIdx].name; selection = itemName; store.startTimer(for: itemName) }
                                    .swipeActions(edge: .leading) { Button("重命名") { triggerRename(title: "重命名技能", current: store.folders[fIdx].items[iIdx].name) { store.folders[fIdx].items[iIdx].name = $0 } }.tint(.orange) }
                                    // 加入“归档”与“删除”
                                    .swipeActions(edge: .trailing) {
                                        Button("删除", role: .destructive) { store.trash.append(store.folders[fIdx].items[iIdx].name); store.folders[fIdx].items.remove(at: iIdx); store.save() }
                                        Button("归档") { store.archive.append(store.folders[fIdx].items[iIdx].name); store.folders[fIdx].items.remove(at: iIdx); store.save() }.tint(.blue)
                                    }
                                }
                                Button("+ 开启新技能") { store.folders[fIdx].items.append(FocusItem(name: "新技能")); store.save() }
                            } label: {
                                Text(store.folders[fIdx].name)
                                    .contextMenu {
                                        Button(action: { triggerRename(title: "重命名领域", current: store.folders[fIdx].name) { store.folders[fIdx].name = $0 } }) { Label("重命名领域", systemImage: "pencil") }
                                        Button(action: { store.archive.append(store.folders[fIdx].name); store.folders.remove(at: fIdx); store.save() }) { Label("归档领域", systemImage: "archivebox") }
                                        Button(role: .destructive, action: { store.trash.append(store.folders[fIdx].name); store.folders.remove(at: fIdx); store.save() }) { Label("删除领域", systemImage: "trash") }
                                    }
                            }
                        }
                        Button("+ 探索新领域") { store.folders.append(Folder(name: "新领域")); store.save() }
                    }
                    
                    // 核心修复：找回归档区与回收站
                    if !store.archive.isEmpty {
                        Section("归档区 (曾经的闪光)") {
                            ForEach(store.archive, id: \.self) { item in
                                Text(item).foregroundColor(.blue.opacity(0.8))
                                    .swipeActions(edge: .leading) {
                                        Button("重新激活") {
                                            store.folders[0].items.append(FocusItem(name: item))
                                            if let idx = store.archive.firstIndex(of: item) { store.archive.remove(at: idx) }
                                            store.save()
                                        }.tint(.green)
                                    }
                            }
                        }
                    }
                    
                    if !store.trash.isEmpty {
                        Section("回收站") {
                            ForEach(store.trash, id: \.self) { item in
                                Text(item).foregroundColor(.secondary)
                                    .swipeActions(edge: .trailing) {
                                        Button("彻底粉碎", role: .destructive) {
                                            if let idx = store.trash.firstIndex(of: item) { store.trash.remove(at: idx); store.save() }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { Spacer().frame(height: (store.isTimerRunning && selection != store.activeFocusItem && selection != "QUICK_START") ? 100 : 20) }
            .alert(renameTitle, isPresented: $showRenameAlert) { TextField("新名称", text: $renameInput); Button("保存") { renameAction?() }; Button("取消", role: .cancel) {} }
            .sheet(isPresented: $showManualLog) { ManualLogView(store: store) }
            .sheet(isPresented: $showMomentCapture) { MomentCaptureView(store: store) }
            
        } detail: {
            NavigationStack {
                if let s = selection {
                    if s == "CALENDAR" { CalendarSummaryView(store: store) }
                    else if s == "MISSION_INSIGHT" { MissionInsightView(store: store) }
                    else if s == "QUICK_START" { TimerView(store: store, itemName: "未分类探索", selection: $selection) }
                    else { TimerView(store: store, itemName: s, selection: $selection) }
                } else { Text("选择一条路，开始你的丈量").foregroundColor(.gray.opacity(0.4)).font(.title2) }
            }
        }
        .onChange(of: scenePhase) { newPhase in if newPhase == .inactive || newPhase == .background { store.save() } }
        .overlay(alignment: .bottom) {
            if store.isTimerRunning && selection != store.activeFocusItem && selection != "QUICK_START" {
                HStack(spacing: 15) {
                    Image(systemName: "hourglass").font(.title3).rotation3DEffect(.degrees(isBreathing ? 180 : 0), axis: (x: 0, y: 1, z: 0)).animation(.easeInOut(duration: 2).repeatForever(autoreverses: false), value: isBreathing)
                    VStack(alignment: .leading, spacing: 2) { Text("正在丈量: \(store.activeFocusItem ?? "未知")").font(.headline); Text(formatTime(store.activeTimeElapsed)).font(.subheadline).opacity(0.8) }
                    Spacer()
                    Button("回到专注") { selection = store.activeFocusItem }.buttonStyle(.bordered).tint(.white)
                }
                .padding().background(Color(hex: store.dominantEmotionTag.hex)).foregroundColor(.white).cornerRadius(16).shadow(color: Color(hex: store.dominantEmotionTag.hex).opacity(0.4), radius: 10, x: 0, y: 5)
                .padding(.horizontal, 20).padding(.bottom, 30).scaleEffect(isBreathing ? 1.02 : 0.98)
                .onAppear { withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { isBreathing = true } }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
    func triggerRename(title: String, current: String, onSave: @escaping (String) -> Void) { renameTitle = title; renameInput = current; showRenameAlert = true; renameAction = { if !renameInput.isEmpty { onSave(renameInput) }; store.save() } }
    func formatTime(_ seconds: Int) -> String { return seconds == 0 ? "✨ 一瞬间" : String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

// --- 3. 专注计时器与【语音录入】 ---
struct TimerView: View {
    @ObservedObject var store: AppDataStore; var itemName: String; @Binding var selection: String?
    @State private var showSheet = false; @State private var currentThought = ""
    @StateObject private var speechManager = SpeechManager()
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 40); Text(itemName).font(.title).bold()
            Text(formatDisplayTime(store.activeFocusItem == itemName ? store.activeTimeElapsed : 0)).font(.system(size: 80, weight: .thin, design: .rounded)).padding(.vertical, 20)
            HStack(spacing: 20) {
                if store.isTimerRunning && store.activeFocusItem == itemName {
                    Button(action: { store.pauseTimer() }) { Image(systemName: "pause.fill").font(.title2).padding() }.buttonStyle(.bordered).tint(.orange)
                    Button("结束并封存") { store.pauseTimer(); showSheet = true }.buttonStyle(.borderedProminent).tint(Color(hex: store.dominantEmotionTag.hex)).controlSize(.large)
                } else { Button("开始专注") { store.startTimer(for: itemName) }.buttonStyle(.borderedProminent).tint(Color(hex: store.dominantEmotionTag.hex)).controlSize(.large) }
            }
            Divider().padding(.vertical, 30)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.sessionThoughts.indices, id: \.self) { idx in HStack { Text(store.sessionThoughts[idx]).padding(12).background(Color.gray.opacity(0.1)).cornerRadius(12); Spacer() }.id(idx) }
                    }.padding(.horizontal)
                }.onChange(of: store.sessionThoughts.count) { _ in if !store.sessionThoughts.isEmpty { withAnimation { proxy.scrollTo(store.sessionThoughts.count - 1, anchor: .bottom) } } }
            }
            
            HStack {
                Button(action: { speechManager.toggleRecording() }) {
                    Image(systemName: speechManager.isRecording ? "mic.fill" : "mic").font(.title2).foregroundColor(speechManager.isRecording ? .red : .gray).scaleEffect(speechManager.isRecording ? 1.2 : 1.0).animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: speechManager.isRecording)
                }
                TextField("闪念，写一句或说一句...", text: $currentThought).textFieldStyle(.roundedBorder).onSubmit { saveThought() }
                    .onChange(of: speechManager.transcript) { newVal in if !newVal.isEmpty { currentThought = newVal } }
                Button(action: saveThought) { Image(systemName: "arrow.up.circle.fill").font(.title).foregroundColor(currentThought.isEmpty ? .gray : Color(hex: store.dominantEmotionTag.hex)) }.disabled(currentThought.isEmpty)
            }.padding().background(Color(UIColor.systemBackground).shadow(color: .black.opacity(0.05), radius: 5, y: -5))
        }
        .onDisappear { speechManager.stopRecording() }
        .sheet(isPresented: $showSheet) { CategorizeView(store: store, itemName: itemName, duration: store.activeTimeElapsed) { store.resetTimer(); selection = "CALENDAR" } }
    }
    func saveThought() { guard !currentThought.isEmpty else { return }; store.sessionThoughts.append(currentThought); store.save(); currentThought = ""; speechManager.stopRecording() }
    func formatDisplayTime(_ seconds: Int) -> String { return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

// --- 4. 捕捉瞬间 ---
struct MomentCaptureView: View {
    @ObservedObject var store: AppDataStore; @Environment(\.dismiss) var dismiss
    @State private var selectedEmotion = ""; @State private var note = ""; @State private var photoItem: PhotosPickerItem?; @State private var selectedImageData: Data?
    @StateObject private var speechManager = SpeechManager()
    var body: some View {
        NavigationStack {
            Form {
                Section("当下的能量") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(store.emotionTags) { tag in
                                Text(tag.name).font(.subheadline).bold().padding(.horizontal, 16).padding(.vertical, 8).background(selectedEmotion == tag.name ? Color(hex: tag.hex) : Color.gray.opacity(0.1)).foregroundColor(selectedEmotion == tag.name ? .white : .primary).cornerRadius(20).onTapGesture { selectedEmotion = tag.name }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    HStack(alignment: .top) {
                        TextEditor(text: $note).frame(height: 100).overlay(Text(note.isEmpty ? "这一瞬间，你感受到了什么？" : "").foregroundColor(.gray).padding(8).allowsHitTesting(false), alignment: .topLeading).onChange(of: speechManager.transcript) { newVal in if !newVal.isEmpty { note = newVal } }
                        Button(action: { speechManager.toggleRecording() }) { VStack { Image(systemName: speechManager.isRecording ? "mic.fill" : "mic").font(.title).foregroundColor(speechManager.isRecording ? .red : .gray); Text(speechManager.isRecording ? "说话中" : "录音").font(.caption2).foregroundColor(.gray) }.padding(.top, 8) }.buttonStyle(.borderless)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) { HStack { Image(systemName: "photo.badge.plus"); Text(selectedImageData == nil ? "附上一张图" : "更改图片") }.foregroundColor(Color(hex: store.dominantEmotionTag.hex)) }
                    .onChange(of: photoItem) { newItem in Task { if let data = try? await newItem?.loadTransferable(type: Data.self) { selectedImageData = data } } }
                    if let imgData = selectedImageData, let uiImage = UIImage(data: imgData) { Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 200).cornerRadius(10) }
                } header: { Text("灵感碎片") }
            }
            .navigationTitle("✨ 捕捉瞬间").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("定格") { store.logs.append(SessionLog(itemName: "人生闪念", duration: 0, emotion: selectedEmotion.isEmpty ? (store.emotionTags.first?.name ?? "顺流") : selectedEmotion, date: Date(), note: note, imageData: selectedImageData)); store.save(); dismiss() }.bold() }
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }.onAppear { selectedEmotion = store.dominantEmotionTag.name }.onDisappear { speechManager.stopRecording() }
        }
    }
}

// --- 5. 觉察日历升级 (加入动态能量光谱 & 原生时间线日视图) ---
struct CalendarSummaryView: View {
    @ObservedObject var store: AppDataStore
    @State private var viewMode = 0; @State private var selectedDate = Date(); @State private var monthOffset = 0
    let calendar = Calendar.current
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("视图模式", selection: $viewMode) { Text("月视图").tag(0); Text("年视图").tag(1) }.pickerStyle(.segmented).padding()
            
            let baseDate = calendar.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
            let currentLogs = store.logs.filter {
                viewMode == 0 ? calendar.isDate($0.date, equalTo: baseDate, toGranularity: .month) : calendar.isDate($0.date, equalTo: baseDate, toGranularity: .year)
            }
            
            if !currentLogs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(viewMode == 0 ? "本月生命图谱" : "本年生命图谱").font(.caption).foregroundColor(.secondary)
                    EnergyProportionBar(logs: currentLogs, tags: store.emotionTags)
                }.padding(.horizontal).padding(.bottom, 10)
            }
            
            if viewMode == 0 {
                HStack {
                    Button(action: { monthOffset -= 1 }) { Image(systemName: "chevron.left").padding() }
                    Spacer(); Text(baseDate.formatted(.dateTime.year().month())).font(.title3).bold(); Spacer()
                    Button(action: { monthOffset += 1 }) { Image(systemName: "chevron.right").padding() }
                }.padding(.horizontal)
                
                HStack { ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in Text(day).frame(maxWidth: .infinity).font(.caption).foregroundColor(.secondary) } }.padding(.horizontal)
                
                let days = daysInMonth(baseDate: baseDate)
                let logsByDay = Dictionary(grouping: store.logs) { calendar.startOfDay(for: $0.date) }
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                    ForEach(0..<days.count, id: \.self) { index in
                        if let date = days[index] {
                            let dayLogs = logsByDay[calendar.startOfDay(for: date)] ?? []
                            let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                            let isToday = calendar.isDateInToday(date)
                            
                            ZStack {
                                if !dayLogs.isEmpty { Circle().fill(Color(hex: store.dominantColor(for: dayLogs))).opacity(0.5) }
                                if isSelected { Circle().stroke(Color.primary, lineWidth: 1.5) }
                                Text("\(calendar.component(.day, from: date))").font(.system(size: 14)).foregroundColor(isToday ? .blue : .primary)
                            }.frame(height: 32).onTapGesture { selectedDate = date }
                        } else { Color.clear.frame(height: 32) }
                    }
                }.padding(.horizontal)
                
                Divider().padding(.vertical, 8)
                
                // 核心重构：Apple Calendar 原生风格的时间轴日视图
                let selectedLogs = store.logs.filter { calendar.isDate($0.date, inSameDayAs: selectedDate) }.sorted(by: { $0.date < $1.date })
                if selectedLogs.isEmpty { Spacer(); Text("这一天是一段纯白的日子").foregroundColor(.gray).italic(); Spacer() }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(selectedLogs) { log in
                                HStack(alignment: .top) {
                                    // 左侧：具体时间戳
                                    VStack(alignment: .trailing, spacing: 4) {
                                        if log.duration == 0 {
                                            Text(log.date.formatted(date: .omitted, time: .shortened)).font(.caption).bold().foregroundColor(.primary)
                                        } else {
                                            let startTime = log.date.addingTimeInterval(-Double(log.duration))
                                            Text(startTime.formatted(date: .omitted, time: .shortened)).font(.caption).bold().foregroundColor(.primary)
                                            Text(log.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(width: 60, alignment: .trailing).padding(.trailing, 8).padding(.top, 4)
                                    
                                    // 中间：状态时间轴
                                    let tagColor = Color(hex: store.emotionTags.first(where: { $0.name == log.emotion })?.hex ?? "32C1B8")
                                    VStack {
                                        Circle().fill(tagColor).frame(width: 10, height: 10).padding(.top, 6)
                                        Rectangle().fill(tagColor.opacity(0.3)).frame(width: 2)
                                    }
                                    
                                    // 右侧：内容卡片
                                    NavigationLink(destination: LogDetailView(log: log)) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(log.itemName).font(.subheadline).bold().foregroundColor(.primary)
                                                Spacer()
                                                Text(log.duration == 0 ? "✨ 闪念" : "\(log.duration / 60) 分钟").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 3).background(tagColor.opacity(0.15)).cornerRadius(4).foregroundColor(tagColor)
                                            }
                                            if !log.note.isEmpty { Text(log.note).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                                            if log.imageData != nil { Image(systemName: "photo").font(.caption).foregroundColor(.gray) }
                                        }
                                        .padding().background(Color.gray.opacity(0.06)).cornerRadius(12)
                                    }.buttonStyle(.plain).padding(.bottom, 20)
                                }
                            }
                        }.padding(.horizontal)
                    }
                }
            } else {
                ScrollView {
                    let currentYear = calendar.component(.year, from: baseDate)
                    HStack {
                        Button(action: { monthOffset -= 12 }) { Image(systemName: "chevron.left").padding() }
                        Spacer(); Text("\(String(currentYear)) 年生命热力图").font(.headline); Spacer()
                        Button(action: { monthOffset += 12 }) { Image(systemName: "chevron.right").padding() }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 15) {
                        ForEach(1...12, id: \.self) { month in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(month)月").font(.caption).bold()
                                let daysInMonthRange = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: currentYear, month: month))!)?.count ?? 30
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(8), spacing: 2), count: 7), spacing: 2) {
                                    ForEach(1...daysInMonthRange, id: \.self) { day in
                                        let targetDate = calendar.date(from: DateComponents(year: currentYear, month: month, day: day))!
                                        let dayLogs = store.logs.filter { calendar.isDate($0.date, inSameDayAs: targetDate) }
                                        RoundedRectangle(cornerRadius: 1.5).fill(dayLogs.isEmpty ? Color.gray.opacity(0.1) : Color(hex: store.dominantColor(for: dayLogs))).frame(width: 8, height: 8)
                                    }
                                }
                            }.padding(8).background(Color.gray.opacity(0.03)).cornerRadius(6)
                        }
                    }.padding()
                }
            }
        }.navigationTitle("觉察日历").navigationBarTitleDisplayMode(.inline)
    }
    func daysInMonth(baseDate: Date) -> [Date?] {
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: baseDate)), let range = calendar.range(of: .day, in: .month, for: startOfMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: startOfMonth)
        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in 1...range.count { if let d = calendar.date(byAdding: .day, value: day - 1, to: startOfMonth) { days.append(d) } }
        return days
    }
}

struct EnergyProportionBar: View {
    var logs: [SessionLog]; var tags: [EmotionTag]
    var body: some View {
        let stats = Dictionary(grouping: logs, by: { $0.emotion })
        let total = max(1, logs.reduce(0) { $0 + max($1.duration, 300) })
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(tags) { tag in
                    let duration = stats[tag.name]?.reduce(0) { $0 + max($1.duration, 300) } ?? 0
                    if duration > 0 {
                        Color(hex: tag.hex).frame(width: max(0, geo.size.width * CGFloat(duration) / CGFloat(total)))
                            .overlay(Text(String(format: "%.0f%%", Double(duration)/Double(total)*100)).font(.system(size: 9)).bold().foregroundColor(.white).opacity(0.8))
                    }
                }
            }.cornerRadius(8)
        }.frame(height: 20)
    }
}

extension AppDataStore {
    func dominantColor(for logs: [SessionLog]) -> String {
        let counts = Dictionary(grouping: logs, by: { $0.emotion }).mapValues { $0.reduce(0){ $0 + max($1.duration, 60) } }
        if let maxEmotion = counts.max(by: { $0.value < $1.value })?.key, let tag = emotionTags.first(where: { $0.name == maxEmotion }) { return tag.hex }
        return "32C1B8"
    }
}

// --- 其余复盘/归档/洞察组件保持极度稳定 ---
struct CategorizeView: View {
    @ObservedObject var store: AppDataStore; var itemName: String; var duration: Int; var onDismiss: () -> Void
    @State private var selectedEmotion = ""; @State private var selectedItem = ""; @State private var note = ""; @State private var photoItem: PhotosPickerItem?; @State private var selectedImageData: Data?
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("基本盘") {
                    HStack { Text("本次投入"); Spacer(); Text("\(duration) 秒").bold() }
                    Picker("所在领域", selection: $selectedItem) { ForEach(store.folders.flatMap { $0.items }) { item in Text(item.name).tag(item.name) } }
                    Picker("当时状态", selection: $selectedEmotion) { ForEach(store.emotionTags) { tag in Text(tag.name).tag(tag.name) } }
                }
                Section("思想碎片") { TextEditor(text: $note).frame(height: 100) }
                Section("视觉存档") {
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("附上一张沿途风景", systemImage: "photo.badge.plus") }
                    .onChange(of: photoItem) { newItem in Task { if let data = try? await newItem?.loadTransferable(type: Data.self) { selectedImageData = data } } }
                    if let imgData = selectedImageData, let uiImage = UIImage(data: imgData) { Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 200).cornerRadius(10) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("封存") { store.logs.append(SessionLog(itemName: selectedItem.isEmpty ? itemName : selectedItem, duration: duration, emotion: selectedEmotion.isEmpty ? store.dominantEmotionTag.name : selectedEmotion, note: note, imageData: selectedImageData)); store.save(); onDismiss(); dismiss() } }
                ToolbarItem(placement: .cancellationAction) { Button("舍弃") { onDismiss(); dismiss() } }
            }.onAppear { selectedItem = itemName; selectedEmotion = store.dominantEmotionTag.name; note = store.sessionThoughts.joined(separator: "\n") }
        }
    }
}

struct ManualLogView: View {
    @ObservedObject var store: AppDataStore; @Environment(\.dismiss) var dismiss
    @State private var logDate = Date(); @State private var durationMins = 30; @State private var selectedItem = ""; @State private var selectedEmotion = ""; @State private var note = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("补记时光") {
                    DatePicker("发生时间", selection: $logDate); Stepper("投入时长: \(durationMins) 分钟", value: $durationMins, in: 1...1440)
                    Picker("所在领域", selection: $selectedItem) { ForEach(store.folders.flatMap { $0.items }) { item in Text(item.name).tag(item.name) } }
                    Picker("当时状态", selection: $selectedEmotion) { ForEach(store.emotionTags) { tag in Text(tag.name).tag(tag.name) } }
                }
                Section("事后觉察") { TextEditor(text: $note).frame(height: 100).overlay(Text(note.isEmpty ? "写下那段时间的体验碎片..." : "").foregroundColor(.gray).padding(8).allowsHitTesting(false), alignment: .topLeading) }
            }.navigationTitle("手动补记").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("入库") { store.logs.append(SessionLog(itemName: selectedItem.isEmpty ? (store.folders.first?.items.first?.name ?? "未分类") : selectedItem, duration: durationMins * 60, emotion: selectedEmotion.isEmpty ? store.dominantEmotionTag.name : selectedEmotion, date: logDate, note: note)); store.save(); dismiss() } }
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }.onAppear { selectedItem = store.folders.first?.items.first?.name ?? ""; selectedEmotion = store.dominantEmotionTag.name }
        }
    }
}

struct LogDetailView: View {
    var log: SessionLog
    var body: some View {
        Form {
            Section("足迹属性") { LabeledContent("领域/技能", value: log.itemName); LabeledContent("投入时长", value: log.duration == 0 ? "✨ 一瞬间" : "\(log.duration/60)分"); LabeledContent("体感", value: log.emotion) }
            Section("思想碎片") { Text(log.note.isEmpty ? "留白也是一种记录。" : log.note).padding(.vertical, 4) }
            if let imgData = log.imageData, let uiImage = UIImage(data: imgData) { Section("视觉印记") { Image(uiImage: uiImage).resizable().scaledToFit() } }
        }.navigationTitle("复盘详情")
    }
}

struct MissionInsightView: View {
    @ObservedObject var store: AppDataStore
    var body: some View {
        List {
            Section { ShareLink(item: store.generateCSVExport()) { Label("导出人生资料包 (CSV)", systemImage: "square.and.arrow.up").bold() }.foregroundColor(Color(hex: store.dominantEmotionTag.hex)).frame(maxWidth: .infinity, alignment: .center) }
            Section("全局能量分布 (含闪念)") {
                let emotionStats = Dictionary(grouping: store.logs, by: { $0.emotion })
                ForEach(store.emotionTags) { tag in
                    let logs = emotionStats[tag.name] ?? []; let totalTime = logs.reduce(0) { $0 + $1.duration }; let momentCount = logs.filter { $0.duration == 0 }.count
                    if totalTime > 0 || momentCount > 0 {
                        DisclosureGroup {
                            let itemStats = Dictionary(grouping: logs, by: { $0.itemName })
                            ForEach(itemStats.keys.sorted(), id: \.self) { name in let iTime = itemStats[name]!.reduce(0){$0+$1.duration}; let iCount = itemStats[name]!.filter{$0.duration == 0}.count; HStack { Text(name).font(.subheadline); Spacer(); Text(iTime > 0 ? "\(iTime/60) 分" : "\(iCount) 次闪念").font(.subheadline).foregroundColor(.secondary) } }
                        } label: { HStack { Circle().fill(Color(hex: tag.hex)).frame(width: 12, height: 12); Text(tag.name).bold(); Spacer(); Text(totalTime > 0 ? "\(totalTime/60) 分" : "\(momentCount) 次闪念").foregroundColor(.secondary) } }
                    }
                }
            }
        }.navigationTitle("使命洞察")
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted); var int: UInt64 = 0; Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64; switch hex.count { case 3: (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17); case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF); default: (r, g, b) = (128, 128, 128) }
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
    func toHex() -> String {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return "808080" }
        return String(format: "%02lX%02lX%02lX", lroundf(Float(components[0]) * 255), lroundf(Float(components[1]) * 255), lroundf(Float(components[2]) * 255))
    }
}
