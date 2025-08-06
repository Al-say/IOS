//
//  ContentView.swift
//  Alsay_IOS
//
//  Created by Alsay_Mac on 2025/8/2.
//

import SwiftUI
import Foundation
import UIKit

enum NotePriority: String, CaseIterable, Codable {
    case low = "低"
    case normal = "普通"
    case high = "高"
    
    var color: Color {
        switch self {
        case .low: return .green
        case .normal: return .blue
        case .high: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .low: return "arrow.down.circle"
        case .normal: return "minus.circle"
        case .high: return "arrow.up.circle"
        }
    }
}

struct Note: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    var dateCreated: Date
    var dateModified: Date
    var priority: NotePriority
    var isFavorite: Bool
    var tags: [String]
    var isArchived: Bool
    var reminderDate: Date?
    
    // 缓存字数计算结果
    private var _wordCount: Int?
    var wordCount: Int {
        if let cached = _wordCount {
            return cached
        }
        let count = content.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count
        // 注意：由于 Codable 限制，这里不能直接缓存
        return count
    }
    
    init(title: String, content: String, priority: NotePriority = .normal) {
        self.id = UUID()
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dateCreated = Date()
        self.dateModified = Date()
        self.priority = priority
        self.isFavorite = false
        self.tags = []
        self.isArchived = false
        self.reminderDate = nil
    }
    
    // 为 Codable 提供安全的解码初始化器
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // 必需字段
        self.id = try container.decode(UUID.self, forKey: .id)
        
        // 可选字段，提供默认值
        self.title = (try? container.decode(String.self, forKey: .title)) ?? "无标题"
        self.content = (try? container.decode(String.self, forKey: .content)) ?? ""
        self.dateCreated = (try? container.decode(Date.self, forKey: .dateCreated)) ?? Date()
        self.dateModified = (try? container.decode(Date.self, forKey: .dateModified)) ?? Date()
        self.priority = (try? container.decode(NotePriority.self, forKey: .priority)) ?? .normal
        self.isFavorite = (try? container.decode(Bool.self, forKey: .isFavorite)) ?? false
        self.tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        self.isArchived = (try? container.decode(Bool.self, forKey: .isArchived)) ?? false
        self.reminderDate = try? container.decode(Date.self, forKey: .reminderDate)
        
        // 验证数据完整性
        if self.dateModified < self.dateCreated {
            self.dateModified = self.dateCreated
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, title, content, dateCreated, dateModified, priority, isFavorite, tags, isArchived, reminderDate
    }
}

/*
 * ContentView - 主应用界面
 * 
 * 性能优化实现：
 * 1. 智能缓存系统：使用哈希值检测过滤条件变化，避免不必要的重新计算
 * 2. 搜索防抖：延迟搜索请求以减少频繁的过滤操作
 * 3. 懒加载优化：大列表使用LazyVStack，小列表保持List功能
 * 4. 后台处理：数据保存和编码在后台线程执行，避免UI阻塞
 * 5. 内存管理：定期清理缓存，监控内存使用
 * 6. UI渲染优化：预计算显示属性，减少实时计算
 * 7. 数据验证：延迟执行数据健康检查，不阻塞应用启动
 */
struct ContentView: View {
    @State private var notes: [Note] = []
    @State private var showingAddNote = false
    @State private var selectedNote: Note?
    @State private var showingNoteDetail = false
    @State private var searchText = ""
    @State private var selectedPriority: NotePriority? = nil
    @State private var showFavoritesOnly = false
    @State private var showArchivedNotes = false
    @State private var sortOption: SortOption = .dateModified
    @State private var selectedTag: String? = nil
    @State private var showingSettings = false
    @State private var isDarkMode = false
    @State private var showingStatistics = false
    
    // 性能优化：缓存计算结果
    @State private var cachedFilteredNotes: [Note] = []
    @State private var lastFilterHash: Int = 0
    @State private var searchTimer: Timer?
    @State private var memoryCleanupTimer: Timer?
    @State private var cacheCleanupCounter: Int = 0
    
    // 高级性能优化
    @State private var isDataLoaded = false
    @State private var prefetchedTags: Set<String> = []
    @State private var viewModelCache: [String: Any] = [:]
    @State private var lastAccessTime = Date()
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier?
    
    enum SortOption: String, CaseIterable {
        case dateModified = "修改时间"
        case dateCreated = "创建时间"
        case title = "标题"
        case priority = "优先级"
        case wordCount = "字数"
    }
    
    var filteredNotes: [Note] {
        // 创建过滤条件的哈希值
        let currentHash = generateFilterHash()
        
        // 如果过滤条件没有变化，返回缓存结果
        if currentHash == lastFilterHash && !cachedFilteredNotes.isEmpty {
            return cachedFilteredNotes
        }
        
        var filtered = notes
        
        // 归档过滤 - 最先执行以减少后续处理的数据量
        filtered = filtered.filter { $0.isArchived == showArchivedNotes }
        
        // 优先级过滤 - 简单比较，提前执行
        if let priority = selectedPriority {
            filtered = filtered.filter { $0.priority == priority }
        }
        
        // 收藏过滤
        if showFavoritesOnly {
            filtered = filtered.filter { $0.isFavorite }
        }
        
        // 标签过滤
        if let tag = selectedTag {
            filtered = filtered.filter { $0.tags.contains(tag) }
        }
        
        // 搜索过滤 - 最耗时的操作放在最后
        if !searchText.isEmpty {
            let searchLower = searchText.lowercased()
            filtered = filtered.filter { note in
                note.title.lowercased().contains(searchLower) ||
                note.content.lowercased().contains(searchLower) ||
                note.tags.contains { $0.lowercased().contains(searchLower) }
            }
        }
        
        // 排序 - 使用更高效的排序
        switch sortOption {
        case .dateModified:
            filtered.sort { $0.dateModified > $1.dateModified }
        case .dateCreated:
            filtered.sort { $0.dateCreated > $1.dateCreated }
        case .title:
            filtered.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .priority:
            filtered.sort { priorityValue($0.priority) > priorityValue($1.priority) }
        case .wordCount:
            filtered.sort { $0.wordCount > $1.wordCount }
        }
        
        // 缓存结果
        DispatchQueue.main.async {
            self.cachedFilteredNotes = filtered
            self.lastFilterHash = currentHash
        }
        
        return filtered
    }
    
    private func generateFilterHash() -> Int {
        var hasher = Hasher()
        hasher.combine(showArchivedNotes)
        hasher.combine(searchText)
        hasher.combine(selectedPriority)
        hasher.combine(showFavoritesOnly)
        hasher.combine(selectedTag)
        hasher.combine(sortOption)
        hasher.combine(notes.count)
        return hasher.finalize()
    }
    
    var allTags: [String] {
        // 检查缓存是否有效
        let cacheKey = "allTags_\(notes.count)"
        if let cachedTags = viewModelCache[cacheKey] as? [String] {
            return cachedTags
        }
        
        // 使用Set来避免重复，然后排序
        let uniqueTags = Set(notes.flatMap { $0.tags }.filter { !$0.isEmpty })
        let sortedTags = Array(uniqueTags).sorted()
        
        // 缓存结果
        viewModelCache[cacheKey] = sortedTags
        return sortedTags
    }
    
    var statistics: (totalNotes: Int, favoriteNotes: Int, archivedNotes: Int, totalWords: Int) {
        // 检查统计数据缓存
        let cacheKey = "statistics_\(notes.count)_\(notes.map{$0.dateModified}.max() ?? Date())"
        if let cached = viewModelCache[cacheKey] as? (Int, Int, Int, Int) {
            return cached
        }
        
        let totalNotes = notes.filter { !$0.isArchived }.count
        let favoriteNotes = notes.filter { $0.isFavorite && !$0.isArchived }.count
        let archivedNotes = notes.filter { $0.isArchived }.count
        let totalWords = notes.filter { !$0.isArchived }.reduce(0) { $0 + $1.wordCount }
        
        let result = (totalNotes, favoriteNotes, archivedNotes, totalWords)
        viewModelCache[cacheKey] = result
        return result
    }
    
    func priorityValue(_ priority: NotePriority) -> Int {
        switch priority {
        case .high: return 3
        case .normal: return 2
        case .low: return 1
        }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // 视图切换器
                ViewSwitcher(showArchivedNotes: $showArchivedNotes)
                
                // 搜索栏
                SearchBar(text: $searchText)
                
                // 过滤器栏
                FilterBar(
                    selectedPriority: $selectedPriority,
                    showFavoritesOnly: $showFavoritesOnly,
                    sortOption: $sortOption,
                    selectedTag: $selectedTag,
                    allTags: allTags
                )
                
                // 便签列表
                if filteredNotes.isEmpty {
                    EmptyStateView(hasNotes: !notes.isEmpty, isArchived: showArchivedNotes)
                } else {
                    // 根据便签数量选择合适的视图
                    if filteredNotes.count > 50 {
                        // 大列表使用LazyVStack优化性能
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(filteredNotes) { note in
                                    NoteRowView(note: note) { updatedNote in
                                        updateNote(updatedNote)
                                    }
                                    .onTapGesture {
                                        selectedNote = note
                                        showingNoteDetail = true
                                    }
                                    .padding(.horizontal)
                                    .contextMenu {
                                        Button(note.isArchived ? "恢复" : "归档") {
                                            toggleArchive(note)
                                        }
                                        Button(note.isFavorite ? "取消收藏" : "收藏") {
                                            toggleFavorite(note)
                                        }
                                        Button("删除", role: .destructive) {
                                            deleteNote(note)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    } else {
                        // 小列表使用List保持原有功能
                        List {
                            ForEach(filteredNotes) { note in
                                NoteRowView(note: note) { updatedNote in
                                    updateNote(updatedNote)
                                }
                                .onTapGesture {
                                    selectedNote = note
                                    showingNoteDetail = true
                                }
                                .swipeActions(edge: .trailing) {
                                    // 归档/恢复按钮
                                    Button(note.isArchived ? "恢复" : "归档") {
                                        toggleArchive(note)
                                    }
                                    .tint(note.isArchived ? .green : .orange)
                                    
                                    // 删除按钮
                                    Button("删除", role: .destructive) {
                                        deleteNote(note)
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    // 收藏按钮
                                    Button(note.isFavorite ? "取消收藏" : "收藏") {
                                        toggleFavorite(note)
                                    }
                                    .tint(.red)
                                }
                            }
                            .onDelete(perform: deleteNotes)
                        }
                    }
                }
            }
            .navigationTitle(showArchivedNotes ? "归档便签 (\(filteredNotes.count))" : "便签 (\(filteredNotes.count))")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack {
                        // 统计按钮
                        Button(action: {
                            showingStatistics = true
                        }) {
                            Image(systemName: "chart.bar")
                        }
                        
                        // 设置按钮
                        Button(action: {
                            showingSettings = true
                        }) {
                            Image(systemName: "gear")
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingAddNote = true
                    }) {
                        Image(systemName: "plus")
                    }
                    .disabled(showArchivedNotes) // 在归档视图中禁用添加按钮
                }
            }
            .sheet(isPresented: $showingAddNote) {
                AddNoteView { newNote in
                    notes.append(newNote)
                    invalidateCache() // 清除缓存
                    saveNotes()
                }
            }
            .sheet(isPresented: $showingNoteDetail) {
                if let note = selectedNote {
                    NoteDetailView(note: note) { updatedNote in
                        updateNote(updatedNote)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(isDarkMode: $isDarkMode)
            }
            .sheet(isPresented: $showingStatistics) {
                StatisticsView(statistics: statistics, allTags: allTags, notes: notes.filter { !$0.isArchived })
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            // 启动核心系统
            loadNotes() // 现在在后台加载
            loadSettings()
            setupMemoryManagement() // 启动智能内存管理
            
            // 延迟执行非关键操作，避免阻塞UI
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.validateAndFixNotes()
                self.performHealthCheck()
            }
            
            // 监听应用生命周期事件
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                self.handleAppDidEnterBackground()
            }
            
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                self.handleAppWillEnterForeground()
            }
        }
        .onDisappear {
            cleanupMemory() // 清理内存
        }
        .onChange(of: isDarkMode) { _, _ in
            saveSettings()
        }
        .onChange(of: searchText) { _, _ in
            performSearch()
        }
    }
    
    func updateNote(_ updatedNote: Note) {
        guard let index = notes.firstIndex(where: { $0.id == updatedNote.id }) else {
            print("警告：无法找到要更新的便签 ID: \(updatedNote.id)")
            return
        }
        
        // 直接在当前线程更新，因为SwiftUI状态更新应该在主线程
        notes[index] = updatedNote
        invalidateCache() // 清除缓存
        saveNotes()
    }
    
    func deleteNote(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else {
            print("警告：无法找到要删除的便签 ID: \(note.id)")
            return
        }
        notes.remove(at: index)
        invalidateCache() // 清除缓存
        saveNotes()
    }
    
    func toggleArchive(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else {
            print("警告：无法找到要归档的便签 ID: \(note.id)")
            return
        }
        notes[index].isArchived.toggle()
        notes[index].dateModified = Date() // 更新修改时间
        invalidateCache() // 清除缓存
        saveNotes()
    }
    
    func toggleFavorite(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else {
            print("警告：无法找到要收藏的便签 ID: \(note.id)")
            return
        }
        notes[index].isFavorite.toggle()
        notes[index].dateModified = Date() // 更新修改时间
        invalidateCache() // 清除缓存
        saveNotes()
    }
    
    // 清除缓存的辅助函数
    private func invalidateCache() {
        cachedFilteredNotes = []
        lastFilterHash = 0
        // 同时清除高级缓存
        invalidateViewModelCache()
    }
    
    // 高级缓存管理
    private func invalidateViewModelCache() {
        viewModelCache.removeAll()
        prefetchedTags.removeAll()
    }
    
    // 数据预加载和预处理
    private func preloadData() {
        DispatchQueue.global(qos: .userInitiated).async {
            // 预加载标签
            let tags = Set(self.notes.flatMap { $0.tags }.filter { !$0.isEmpty })
            
            // 预计算常用统计数据
            let activeNotes = self.notes.filter { !$0.isArchived }
            let favoriteCount = activeNotes.filter { $0.isFavorite }.count
            let totalWords = activeNotes.reduce(0) { $0 + $1.wordCount }
            
            DispatchQueue.main.async {
                self.prefetchedTags = tags
                // 预填充缓存
                let statsKey = "statistics_\(self.notes.count)_\(self.notes.map{$0.dateModified}.max() ?? Date())"
                self.viewModelCache[statsKey] = (activeNotes.count, favoriteCount, self.notes.filter { $0.isArchived }.count, totalWords)
                
                let tagsKey = "allTags_\(self.notes.count)"
                self.viewModelCache[tagsKey] = Array(tags).sorted()
                
                self.isDataLoaded = true
            }
        }
    }
    
    // 智能缓存清理
    private func smartCacheCleanup() {
        let currentTime = Date()
        
        // 如果5分钟内没有访问，清理缓存
        if currentTime.timeIntervalSince(lastAccessTime) > 300 {
            invalidateViewModelCache()
        }
        
        // 限制缓存大小
        if viewModelCache.count > 50 {
            let keysToRemove = Array(viewModelCache.keys.prefix(viewModelCache.count - 30))
            keysToRemove.forEach { viewModelCache.removeValue(forKey: $0) }
        }
        
        lastAccessTime = currentTime
    }
    
    // 搜索防抖
    private func performSearch() {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            invalidateCache()
        }
    }
    
    // 内存管理：智能清理缓存
    private func setupMemoryManagement() {
        memoryCleanupTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            cacheCleanupCounter += 1
            
            // 执行智能缓存清理
            self.smartCacheCleanup()
            
            // 每5分钟强制清理一次主缓存
            if cacheCleanupCounter >= 10 {
                self.invalidateCache()
                cacheCleanupCounter = 0
                print("执行定期主缓存清理")
            }
            
            // 在后台线程执行内存优化
            DispatchQueue.global(qos: .utility).async {
                // 监控内存使用情况
                let memoryUsage = self.getMemoryUsage()
                
                if memoryUsage > 100 * 1024 * 1024 { // 如果内存使用超过100MB
                    DispatchQueue.main.async {
                        self.aggressiveMemoryCleanup()
                    }
                }
                
                // 清理大型缓存
                if self.cachedFilteredNotes.count > 100 {
                    DispatchQueue.main.async {
                        self.invalidateCache()
                    }
                }
            }
        }
        
        // 监听内存警告
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.handleMemoryWarning()
        }
    }
    
    // 获取当前内存使用量
    private func getMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
    
    // 处理内存警告
    private func handleMemoryWarning() {
        print("收到内存警告，执行紧急清理")
        aggressiveMemoryCleanup()
    }
    
    // 激进的内存清理
    private func aggressiveMemoryCleanup() {
        invalidateCache()
        invalidateViewModelCache()
        
        // 清理系统缓存
        URLCache.shared.removeAllCachedResponses()
        
        // 强制垃圾回收
        autoreleasepool {
            // 临时创建大量对象然后释放，触发垃圾回收
            _ = Array(0..<1000).map { _ in NSObject() }
        }
        
        print("执行激进内存清理完成")
    }
    
    // 后台任务管理
    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DataProcessing") {
            self.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if let taskID = backgroundTaskID {
            UIApplication.shared.endBackgroundTask(taskID)
            backgroundTaskID = .invalid
        }
    }
    
    // 批量数据预处理
    private func batchPreprocessData() {
        beginBackgroundTask()
        
        DispatchQueue.global(qos: .userInitiated).async {
            // 批量计算字数
            for i in 0..<self.notes.count {
                _ = self.notes[i].wordCount
            }
            
            // 预计算排序索引
            let sortedByTitle = self.notes.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let sortedByDate = self.notes.sorted { $0.dateModified > $1.dateModified }
            let sortedByPriority = self.notes.sorted { self.priorityValue($0.priority) > self.priorityValue($1.priority) }
            
            DispatchQueue.main.async {
                // 缓存预计算结果
                self.viewModelCache["sorted_title"] = sortedByTitle.map { $0.id }
                self.viewModelCache["sorted_date"] = sortedByDate.map { $0.id }
                self.viewModelCache["sorted_priority"] = sortedByPriority.map { $0.id }
                
                self.endBackgroundTask()
            }
        }
    }
    
    private func cleanupMemory() {
        searchTimer?.invalidate()
        memoryCleanupTimer?.invalidate()
        invalidateCache()
        invalidateViewModelCache()
        endBackgroundTask()
        
        // 移除通知观察者
        NotificationCenter.default.removeObserver(self)
    }
    
    // 应用生命周期管理
    private func handleAppDidEnterBackground() {
        print("应用进入后台，保存数据并清理缓存")
        
        // 保存数据
        saveNotes()
        
        // 清理非必要缓存
        smartCacheCleanup()
        
        // 记录进入后台时间
        lastAccessTime = Date()
    }
    
    private func handleAppWillEnterForeground() {
        print("应用即将进入前台，恢复优化状态")
        
        // 检查数据完整性
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.validateAndFixNotes()
        }
        
        // 如果长时间在后台，重新加载数据
        if Date().timeIntervalSince(lastAccessTime) > 600 { // 10分钟
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.preloadData()
                self.batchPreprocessData()
            }
        }
        
        lastAccessTime = Date()
    }
    
    func deleteNotes(offsets: IndexSet) {
        // 收集要删除的便签ID，避免索引变化问题
        let notesToDelete = offsets.compactMap { index in
            index < filteredNotes.count ? filteredNotes[index].id : nil
        }
        
        // 从原始数组中删除
        for noteId in notesToDelete {
            if let index = notes.firstIndex(where: { $0.id == noteId }) {
                notes.remove(at: index)
            }
        }
        
        if !notesToDelete.isEmpty {
            saveNotes()
            print("批量删除了 \(notesToDelete.count) 个便签")
        }
    }
    
    // 数据持久化（高度优化版本）
    func saveNotes() {
        // 开始后台任务
        beginBackgroundTask()
        
        // 在后台线程进行编码以避免阻塞UI
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 使用压缩编码以减少存储空间
                let encoder = JSONEncoder()
                encoder.outputFormatting = [] // 压缩格式（无格式化）
                let encoded = try encoder.encode(self.notes)
                
                // 检查数据大小，如果太大则进行额外压缩
                let compressedData = self.compressDataIfNeeded(encoded)
                
                // 回到主线程进行UserDefaults操作
                DispatchQueue.main.async {
                    UserDefaults.standard.set(compressedData, forKey: "SavedNotes")
                    print("成功保存 \(self.notes.count) 个便签，数据大小: \(compressedData.count) 字节")
                    
                    // 成功保存后创建备份（异步）
                    DispatchQueue.global(qos: .utility).async {
                        UserDefaults.standard.set(compressedData, forKey: "SavedNotesBackup")
                        DispatchQueue.main.async {
                            self.endBackgroundTask()
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("保存便签失败: \(error.localizedDescription)")
                    
                    // 如果主保存失败，尝试保存到备份位置
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [] // 压缩格式
                            let backupData = try encoder.encode(self.notes)
                            let compressedBackup = self.compressDataIfNeeded(backupData)
                            
                            DispatchQueue.main.async {
                                UserDefaults.standard.set(compressedBackup, forKey: "SavedNotesBackup")
                                print("已保存到备份位置")
                                self.endBackgroundTask()
                            }
                        } catch {
                            DispatchQueue.main.async {
                                print("备份保存也失败: \(error.localizedDescription)")
                                self.endBackgroundTask()
                            }
                        }
                    }
                }
            }
        }
    }
    
    // 数据压缩辅助函数
    private func compressDataIfNeeded(_ data: Data) -> Data {
        // 如果数据大于1MB，尝试压缩
        if data.count > 1024 * 1024 {
            do {
                let compressed = try (data as NSData).compressed(using: .zlib)
                print("数据压缩：\(data.count) -> \(compressed.count) 字节")
                return compressed as Data
            } catch {
                print("数据压缩失败: \(error.localizedDescription)")
                return data
            }
        }
        return data
    }
    
    // 数据解压缩辅助函数
    private func decompressDataIfNeeded(_ data: Data) -> Data {
        // 尝试解压缩（如果数据被压缩过）
        do {
            let decompressed = try (data as NSData).decompressed(using: .zlib)
            return decompressed as Data
        } catch {
            // 如果解压缩失败，说明数据没有被压缩，直接返回原数据
            return data
        }
    }
    
    func loadNotes() {
        // 在后台线程加载数据以避免阻塞UI
        DispatchQueue.global(qos: .userInitiated).async {
            var loadedNotes: [Note] = []
            
            // 首先尝试加载主数据
            if let data = UserDefaults.standard.data(forKey: "SavedNotes") {
                do {
                    // 尝试解压缩数据
                    let decompressedData = self.decompressDataIfNeeded(data)
                    let decoded = try JSONDecoder().decode([Note].self, from: decompressedData)
                    loadedNotes = decoded
                    print("成功加载 \(loadedNotes.count) 个便签")
                } catch {
                    print("加载主数据失败: \(error.localizedDescription)")
                    
                    // 尝试加载备份数据
                    if let backupData = UserDefaults.standard.data(forKey: "SavedNotesBackup") {
                        do {
                            let decompressedBackup = self.decompressDataIfNeeded(backupData)
                            loadedNotes = try JSONDecoder().decode([Note].self, from: decompressedBackup)
                            print("从备份恢复 \(loadedNotes.count) 个便签")
                            
                            // 在后台重新保存主数据
                            DispatchQueue.global(qos: .utility).async {
                                DispatchQueue.main.async {
                                    self.notes = loadedNotes
                                    self.saveNotes()
                                }
                            }
                        } catch {
                            print("备份数据也损坏: \(error.localizedDescription)")
                            loadedNotes = []
                        }
                    } else {
                        print("没有找到备份数据")
                        loadedNotes = []
                    }
                }
            } else {
                print("没有找到保存的便签数据")
                loadedNotes = []
            }
            
            // 回到主线程更新UI
            DispatchQueue.main.async {
                self.notes = loadedNotes
                
                // 加载完成后进行数据预处理
                if !loadedNotes.isEmpty {
                    self.preloadData()
                    
                    // 延迟执行批量预处理
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.batchPreprocessData()
                    }
                }
                
                self.isDataLoaded = true
            }
        }
    }
    
    func initializeSampleData() {
        // 创建一些示例便签
        let sampleNotes = [
            Note(title: "欢迎使用便签应用", content: "这是您的第一个便签！\n\n您可以：\n• 创建新便签\n• 设置优先级\n• 添加标签\n• 收藏重要便签\n• 归档旧便签", priority: .normal),
            Note(title: "功能介绍", content: "左滑便签可以收藏\n右滑便签可以归档或删除\n点击便签可以查看详情", priority: .low)
        ]
        
        notes = sampleNotes
        saveNotes()
        print("已初始化 \(sampleNotes.count) 个示例便签")
    }
    
    // 应用健康检查
    func performHealthCheck() {
        print("正在执行应用健康检查...")
        
        // 检查UserDefaults的完整性
        let testKey = "HealthCheck_\(Date().timeIntervalSince1970)"
        UserDefaults.standard.set("test", forKey: testKey)
        
        if UserDefaults.standard.string(forKey: testKey) == "test" {
            print("✅ UserDefaults 工作正常")
            UserDefaults.standard.removeObject(forKey: testKey)
        } else {
            print("❌ UserDefaults 存在问题")
        }
        
        // 检查数据完整性
        let totalNotes = notes.count
        let validNotes = notes.filter { !$0.title.isEmpty || !$0.content.isEmpty }.count
        
        print("📊 数据统计：总便签 \(totalNotes) 个，有效便签 \(validNotes) 个")
        
        if totalNotes != validNotes {
            print("⚠️ 发现 \(totalNotes - validNotes) 个空便签")
        }
        
        print("✅ 健康检查完成")
    }
    
    func saveSettings() {
        UserDefaults.standard.set(isDarkMode, forKey: "isDarkMode")
        print("设置已保存：深色模式 = \(isDarkMode)")
    }
    
    func loadSettings() {
        isDarkMode = UserDefaults.standard.bool(forKey: "isDarkMode")
        print("设置已加载：深色模式 = \(isDarkMode)")
    }
    
    // 数据验证和修复
    func validateAndFixNotes() {
        var fixedCount = 0
        let currentDate = Date()
        
        for i in 0..<notes.count {
            var note = notes[i]
            var needsUpdate = false
            
            // 修复空标题
            let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTitle.isEmpty {
                note.title = "无标题"
                needsUpdate = true
            } else if note.title != trimmedTitle {
                note.title = trimmedTitle
                needsUpdate = true
            }
            
            // 修复日期问题
            if note.dateCreated > currentDate {
                note.dateCreated = currentDate
                needsUpdate = true
            }
            
            if note.dateModified < note.dateCreated {
                note.dateModified = note.dateCreated
                needsUpdate = true
            }
            
            // 清理标签：去除空白、重复和无效标签
            let cleanTags = Array(Set(note.tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 20 }
            ))
            
            if cleanTags != note.tags {
                note.tags = cleanTags
                needsUpdate = true
            }
            
            // 验证内容不为空
            if note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note.content = "空内容"
                needsUpdate = true
            }
            
            if needsUpdate {
                notes[i] = note
                fixedCount += 1
            }
        }
        
        if fixedCount > 0 {
            print("已修复 \(fixedCount) 个便签的数据问题")
            saveNotes()
        }
    }
}


struct ViewSwitcher: View {
    @Binding var showArchivedNotes: Bool
    
    var body: some View {
        Picker("视图", selection: $showArchivedNotes) {
            Text("活跃便签").tag(false)
            Text("归档便签").tag(true)
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(.horizontal)
    }
}

struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("搜索便签...", text: $text)
                .textFieldStyle(PlainTextFieldStyle())
            
            if !text.isEmpty {
                Button(action: {
                    text = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal)
    }
}

struct FilterBar: View {
    @Binding var selectedPriority: NotePriority?
    @Binding var showFavoritesOnly: Bool
    @Binding var sortOption: ContentView.SortOption
    @Binding var selectedTag: String?
    let allTags: [String]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // 收藏过滤
                Button(action: {
                    showFavoritesOnly.toggle()
                }) {
                    HStack {
                        Image(systemName: showFavoritesOnly ? "heart.fill" : "heart")
                        Text("收藏")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(showFavoritesOnly ? Color.red.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundColor(showFavoritesOnly ? .red : .primary)
                    .cornerRadius(16)
                }
                
                // 优先级过滤
                ForEach(NotePriority.allCases, id: \.self) { priority in
                    Button(action: {
                        selectedPriority = selectedPriority == priority ? nil : priority
                    }) {
                        HStack {
                            Image(systemName: priority.icon)
                            Text(priority.rawValue)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedPriority == priority ? priority.color.opacity(0.2) : Color.gray.opacity(0.2))
                        .foregroundColor(selectedPriority == priority ? priority.color : .primary)
                        .cornerRadius(16)
                    }
                }
                
                // 标签过滤
                if !allTags.isEmpty {
                    Menu {
                        Button("全部标签") {
                            selectedTag = nil
                        }
                        ForEach(allTags, id: \.self) { tag in
                            Button(action: {
                                selectedTag = selectedTag == tag ? nil : tag
                            }) {
                                HStack {
                                    Text("#\(tag)")
                                    if selectedTag == tag {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "tag")
                            Text(selectedTag ?? "标签")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedTag != nil ? Color.purple.opacity(0.2) : Color.gray.opacity(0.2))
                        .foregroundColor(selectedTag != nil ? .purple : .primary)
                        .cornerRadius(16)
                    }
                }
                
                // 排序选项
                Menu {
                    ForEach(ContentView.SortOption.allCases, id: \.self) { option in
                        Button(action: {
                            sortOption = option
                        }) {
                            HStack {
                                Text(option.rawValue)
                                if sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.arrow.down")
                        Text("排序")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(16)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 4)
    }
}

struct EmptyStateView: View {
    let hasNotes: Bool
    let isArchived: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: getIcon())
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text(getTitle())
                .font(.title2)
                .foregroundColor(.secondary)
            
            Text(getSubtitle())
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
    
    private func getIcon() -> String {
        if isArchived {
            return hasNotes ? "magnifyingglass" : "archivebox"
        } else {
            return hasNotes ? "magnifyingglass" : "note.text"
        }
    }
    
    private func getTitle() -> String {
        if isArchived {
            return hasNotes ? "没有找到匹配的归档便签" : "还没有归档便签"
        } else {
            return hasNotes ? "没有找到匹配的便签" : "还没有便签"
        }
    }
    
    private func getSubtitle() -> String {
        if isArchived {
            return hasNotes ? "尝试调整搜索条件或过滤器" : "归档的便签会显示在这里"
        } else {
            return hasNotes ? "尝试调整搜索条件或过滤器" : "点击右上角的 + 号创建第一个便签"
        }
    }
}

struct NoteRowView: View {
    let note: Note
    let onUpdate: (Note) -> Void
    
    // 预计算显示文本以减少重复计算
    private var displayTitle: String {
        note.title.isEmpty ? "无标题" : note.title
    }
    
    private var displayContent: String {
        // 限制内容长度以提高性能
        let content = note.content
        return content.count > 100 ? String(content.prefix(100)) + "..." : content
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .strikethrough(note.isArchived)
                    
                    Spacer()
                    
                    // 优先级指示器
                    Image(systemName: note.priority.icon)
                        .foregroundColor(note.priority.color)
                        .font(.caption)
                    
                    // 归档指示器
                    if note.isArchived {
                        Image(systemName: "archivebox.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }
                
                Text(displayContent)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                
                // 标签 - 限制显示数量以提高性能
                if !note.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Array(note.tags.prefix(5)), id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }
                            
                            if note.tags.count > 5 {
                                Text("+\(note.tags.count - 5)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                HStack {
                    Text(note.dateModified, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // 字数统计
                    if note.wordCount > 0 {
                        Text("\(note.wordCount) 字")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // 提醒指示器
                    if let reminderDate = note.reminderDate, reminderDate > Date() {
                        Image(systemName: "bell")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }
            }
            
            VStack {
                Button(action: {
                    var updatedNote = note
                    updatedNote.isFavorite.toggle()
                    onUpdate(updatedNote)
                }) {
                    Image(systemName: note.isFavorite ? "heart.fill" : "heart")
                        .foregroundColor(note.isFavorite ? .red : .gray)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
            }
        }
        .padding(.vertical, 2)
        .opacity(note.isArchived ? 0.6 : 1.0)
    }
}

struct AddNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var priority: NotePriority = .normal
    @State private var tagInput = ""
    @State private var tags: [String] = []
    
    let onSave: (Note) -> Void
    
    var body: some View {
        NavigationView {
            VStack {
                Form {
                    Section("基本信息") {
                        TextField("标题", text: $title)
                        
                        Picker("优先级", selection: $priority) {
                            ForEach(NotePriority.allCases, id: \.self) { priority in
                                HStack {
                                    Image(systemName: priority.icon)
                                        .foregroundColor(priority.color)
                                    Text(priority.rawValue)
                                }
                                .tag(priority)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    
                    Section("标签") {
                        HStack {
                            TextField("添加标签", text: $tagInput)
                                .onSubmit {
                                    addTag()
                                }
                            
                            Button("添加", action: addTag)
                                .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        
                        if !tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(tags, id: \.self) { tag in
                                        HStack {
                                            Text("#\(tag)")
                                            Button(action: {
                                                tags.removeAll { $0 == tag }
                                            }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.2))
                                        .foregroundColor(.blue)
                                        .cornerRadius(8)
                                    }
                                }
                            }
                        }
                    }
                    
                    Section("内容") {
                        TextEditor(text: $content)
                            .frame(minHeight: 200)
                    }
                }
            }
            .navigationTitle("新便签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        var newNote = Note(
                            title: trimmedTitle, 
                            content: trimmedContent, 
                            priority: priority
                        )
                        newNote.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(newNote)
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    
    private func addTag() {
        let trimmedTag = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 更严格的标签验证
        guard !trimmedTag.isEmpty,
              trimmedTag.count >= 1 && trimmedTag.count <= 20,
              !trimmedTag.contains("#"),
              !trimmedTag.contains(" "),
              !trimmedTag.contains("\n"),
              !trimmedTag.contains("\t"),
              !tags.contains(where: { $0.lowercased() == trimmedTag.lowercased() }),
              tags.count < 10 else {
            tagInput = ""
            return
        }
        
        tags.append(trimmedTag)
        tagInput = ""
    }
}

struct NoteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var priority: NotePriority
    @State private var tags: [String]
    @State private var isEditing = false
    @State private var tagInput = ""
    @State private var showingShareSheet = false
    @State private var hasUnsavedChanges = false
    
    let note: Note
    let onSave: (Note) -> Void
    
    init(note: Note, onSave: @escaping (Note) -> Void) {
        self.note = note
        self.onSave = onSave
        self._title = State(initialValue: note.title)
        self._content = State(initialValue: note.content)
        self._priority = State(initialValue: note.priority)
        self._tags = State(initialValue: note.tags)
    }
    
    var body: some View {
        NavigationView {
            VStack {
                if isEditing {
                    Form {
                        Section("基本信息") {
                            TextField("标题", text: $title)
                            
                            Picker("优先级", selection: $priority) {
                                ForEach(NotePriority.allCases, id: \.self) { priority in
                                    HStack {
                                        Image(systemName: priority.icon)
                                            .foregroundColor(priority.color)
                                        Text(priority.rawValue)
                                    }
                                    .tag(priority)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                        }
                        
                        Section("标签") {
                            HStack {
                                TextField("添加标签", text: $tagInput)
                                    .onSubmit {
                                        addTag()
                                    }
                                
                                Button("添加", action: addTag)
                                    .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            
                            if !tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(tags, id: \.self) { tag in
                                            HStack {
                                                Text("#\(tag)")
                                                Button(action: {
                                                    tags.removeAll { $0 == tag }
                                                }) {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.2))
                                            .foregroundColor(.blue)
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                        }
                        
                        Section("内容") {
                            TextEditor(text: $content)
                                .frame(minHeight: 200)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // 标题和优先级
                            HStack {
                                if !title.isEmpty {
                                    Text(title)
                                        .font(.title2)
                                        .bold()
                                } else {
                                    Text("无标题")
                                        .font(.title2)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                HStack {
                                    Image(systemName: priority.icon)
                                        .foregroundColor(priority.color)
                                    Text(priority.rawValue)
                                        .font(.caption)
                                        .foregroundColor(priority.color)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(priority.color.opacity(0.2))
                                .cornerRadius(8)
                            }
                            .padding(.horizontal)
                            
                            // 标签
                            if !tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(tags, id: \.self) { tag in
                                            Text("#\(tag)")
                                                .font(.caption)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.2))
                                                .foregroundColor(.blue)
                                                .cornerRadius(8)
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                            
                            // 内容
                            Text(content)
                                .padding(.horizontal)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // 时间信息
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("创建时间:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(note.dateCreated, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(note.dateCreated, style: .time)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                HStack {
                                    Text("修改时间:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(note.dateModified, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(note.dateModified, style: .time)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal)
                            
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑便签" : "便签详情")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: title) { _, _ in
                updateUnsavedChanges()
            }
            .onChange(of: content) { _, _ in
                updateUnsavedChanges()
            }
            .onChange(of: priority) { _, _ in
                updateUnsavedChanges()
            }
            .onChange(of: tags) { _, _ in
                updateUnsavedChanges()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isEditing ? "取消" : "关闭") {
                        if isEditing {
                            if hasUnsavedChanges {
                                // 可以在这里添加确认对话框
                                // 目前直接恢复原始内容
                            }
                            // 恢复原始内容并清理输入状态
                            title = note.title
                            content = note.content
                            priority = note.priority
                            tags = note.tags
                            tagInput = "" // 清理标签输入框
                            isEditing = false
                            hasUnsavedChanges = false
                        } else {
                            dismiss()
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if !isEditing {
                            // 收藏按钮
                            Button(action: {
                                var updatedNote = note
                                updatedNote.isFavorite.toggle()
                                onSave(updatedNote)
                            }) {
                                Image(systemName: note.isFavorite ? "heart.fill" : "heart")
                                    .foregroundColor(note.isFavorite ? .red : .gray)
                            }
                            
                            // 分享按钮
                            Button(action: {
                                showingShareSheet = true
                            }) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        
                        // 编辑/保存按钮
                        Button(isEditing ? "保存" : "编辑") {
                            if isEditing {
                                // 数据验证和清理
                                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                // 验证是否有内容
                                guard !trimmedContent.isEmpty else {
                                    // 如果内容为空，不保存
                                    return
                                }
                                
                                var updatedNote = note
                                updatedNote.title = trimmedTitle.isEmpty ? "无标题" : trimmedTitle
                                updatedNote.content = trimmedContent
                                updatedNote.priority = priority
                                // 清理标签：去除空白和重复
                                updatedNote.tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }))
                                updatedNote.dateModified = Date()
                                onSave(updatedNote)
                                isEditing = false
                                hasUnsavedChanges = false
                            } else {
                                isEditing = true
                            }
                        }
                        .disabled(isEditing && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            let shareText = "\(title.isEmpty ? "无标题" : title)\n\n\(content)"
            ActivityView(activityItems: [shareText])
        }
    }
    
    private func addTag() {
        let trimmedTag = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 更严格的标签验证
        guard !trimmedTag.isEmpty,
              trimmedTag.count >= 1 && trimmedTag.count <= 20,
              !trimmedTag.contains("#"),
              !trimmedTag.contains(" "),
              !trimmedTag.contains("\n"),
              !trimmedTag.contains("\t"),
              !tags.contains(where: { $0.lowercased() == trimmedTag.lowercased() }),
              tags.count < 10 else {
            tagInput = ""
            return
        }
        
        tags.append(trimmedTag)
        tagInput = ""
    }
    
    private func updateUnsavedChanges() {
        hasUnsavedChanges = isEditing && (
            title != note.title ||
            content != note.content ||
            priority != note.priority ||
            tags != note.tags
        )
    }
}

struct StatisticsView: View {
    let statistics: (totalNotes: Int, favoriteNotes: Int, archivedNotes: Int, totalWords: Int)
    let allTags: [String]
    let notes: [Note]
    @Environment(\.dismiss) private var dismiss
    
    private var priorityDistribution: [(NotePriority, Int)] {
        let priorities = NotePriority.allCases
        return priorities.map { priority in
            let count = notes.filter { $0.priority == priority }.count
            return (priority, count)
        }
    }
    
    private var tagUsage: [(String, Int)] {
        let tagCounts = Dictionary(grouping: notes.flatMap { $0.tags }) { $0 }
            .mapValues { $0.count }
        return tagCounts.sorted { $0.value > $1.value }
    }
    
    var body: some View {
        NavigationView {
            List {
                Section("总览") {
                    StatRow(icon: "note.text", title: "活跃便签", value: "\(statistics.totalNotes)")
                    StatRow(icon: "heart.fill", title: "收藏便签", value: "\(statistics.favoriteNotes)", iconColor: .red)
                    StatRow(icon: "archivebox.fill", title: "归档便签", value: "\(statistics.archivedNotes)", iconColor: .orange)
                    StatRow(icon: "textformat", title: "总字数", value: "\(statistics.totalWords)")
                }
                
                Section("优先级分布") {
                    ForEach(priorityDistribution, id: \.0) { priority, count in
                        StatRow(
                            icon: priority.icon,
                            title: priority.rawValue,
                            value: "\(count)",
                            iconColor: priority.color
                        )
                    }
                }
                
                if !tagUsage.isEmpty {
                    Section("标签使用情况") {
                        ForEach(tagUsage.prefix(10), id: \.0) { tag, count in
                            StatRow(
                                icon: "tag.fill",
                                title: "#\(tag)",
                                value: "\(count)",
                                iconColor: .purple
                            )
                        }
                    }
                }
                
                if statistics.totalNotes > 0 {
                    Section("平均数据") {
                        StatRow(
                            icon: "chart.bar",
                            title: "平均字数",
                            value: "\(statistics.totalWords / max(statistics.totalNotes, 1))"
                        )
                        
                        let averageTags = Double(notes.flatMap { $0.tags }.count) / Double(max(statistics.totalNotes, 1))
                        StatRow(
                            icon: "tag.circle",
                            title: "平均标签数",
                            value: String(format: "%.1f", averageTags),
                            iconColor: .purple
                        )
                    }
                }
            }
            .navigationTitle("统计信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct StatRow: View {
    let icon: String
    let title: String
    let value: String
    var iconColor: Color = .blue
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 30)
            
            Text(title)
            
            Spacer()
            
            Text(value)
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
}

struct SettingsView: View {
    @Binding var isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showingExportSheet = false
    @State private var showingDeleteAllAlert = false
    
    var body: some View {
        NavigationView {
            List {
                Section("外观") {
                    HStack {
                        Image(systemName: "moon.fill")
                            .foregroundColor(.purple)
                            .frame(width: 30)
                        
                        Text("深色模式")
                        
                        Spacer()
                        
                        Toggle("", isOn: $isDarkMode)
                    }
                }
                
                Section("数据管理") {
                    Button(action: {
                        showingExportSheet = true
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.blue)
                                .frame(width: 30)
                            
                            Text("导出数据")
                                .foregroundColor(.primary)
                        }
                    }
                    
                    Button(action: {
                        showingDeleteAllAlert = true
                    }) {
                        HStack {
                            Image(systemName: "trash.fill")
                                .foregroundColor(.red)
                                .frame(width: 30)
                            
                            Text("清空所有数据")
                                .foregroundColor(.red)
                        }
                    }
                }
                
                Section("关于") {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.gray)
                            .frame(width: 30)
                        
                        Text("版本")
                        
                        Spacer()
                        
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Image(systemName: "person.circle")
                            .foregroundColor(.gray)
                            .frame(width: 30)
                        
                        Text("开发者")
                        
                        Spacer()
                        
                        Text("Alsay")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            let exportData = createExportData()
            ActivityView(activityItems: [exportData])
        }
        .alert("确认删除", isPresented: $showingDeleteAllAlert) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                deleteAllData()
                dismiss()
            }
        } message: {
            Text("此操作将删除所有便签数据，且无法恢复。")
        }
    }
    
    private func createExportData() -> String {
        guard let data = UserDefaults.standard.data(forKey: "SavedNotes"),
              let notes = try? JSONDecoder().decode([Note].self, from: data) else {
            return "没有找到便签数据"
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        var exportText = "便签数据导出\n"
        exportText += "导出时间: \(dateFormatter.string(from: Date()))\n"
        exportText += "总便签数: \(notes.count)\n\n"
        exportText += String(repeating: "=", count: 50) + "\n\n"
        
        for (index, note) in notes.enumerated() {
            exportText += "便签 \(index + 1)\n"
            exportText += "标题: \(note.title.isEmpty ? "无标题" : note.title)\n"
            exportText += "优先级: \(note.priority.rawValue)\n"
            exportText += "收藏: \(note.isFavorite ? "是" : "否")\n"
            exportText += "归档: \(note.isArchived ? "是" : "否")\n"
            exportText += "创建时间: \(dateFormatter.string(from: note.dateCreated))\n"
            exportText += "修改时间: \(dateFormatter.string(from: note.dateModified))\n"
            if !note.tags.isEmpty {
                exportText += "标签: \(note.tags.map { "#\($0)" }.joined(separator: ", "))\n"
            }
            exportText += "字数: \(note.wordCount)\n"
            exportText += "内容:\n\(note.content)\n"
            exportText += String(repeating: "-", count: 30) + "\n\n"
        }
        
        return exportText
    }
    
    private func deleteAllData() {
        UserDefaults.standard.removeObject(forKey: "SavedNotes")
        UserDefaults.standard.removeObject(forKey: "isDarkMode")
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No update needed
    }
}

#Preview {
    ContentView()
}
