import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - SwiftUI Wrapper (외부 호출부는 이것만 쓴다)

/// AppKit NSTableView 기반 리스트뷰 — Finder/Lightroom 수준 성능 + 멀티 드래그 + 우클릭 메뉴.
/// SwiftUI Table 의 내부 mouse tracking 한계를 회피하고자 직접 구현.
struct NativeTableListView: NSViewRepresentable {
    @EnvironmentObject var store: PhotoStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = ListTableView()
        tableView.coordinator = coord
        coord.tableView = tableView
        tableView.dataSource = coord
        tableView.delegate = coord
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.rowHeight = 40
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.autosaveName = "PickShotListView"
        tableView.autosaveTableColumns = true
        tableView.menu = NSMenu()   // contextMenu 용 — delegate 에서 동적 구성

        // 멀티 드래그 소스 등록
        //   외부(Finder): copy 만 허용 — move 로 실수로 파일 사라지는 것 방지
        //   내부: move (아직 내부 드롭 미구현이지만 placeholder)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.registerForDraggedTypes([.fileURL])

        // 컬럼 구성
        for def in ListColumnDefinition.allColumns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(def.id))
            col.title = def.title
            col.width = def.idealWidth
            col.minWidth = def.minWidth
            col.maxWidth = def.maxWidth
            col.isHidden = def.hiddenByDefault
            col.headerCell.alignment = .center
            col.sortDescriptorPrototype = NSSortDescriptor(key: def.id, ascending: true)
            tableView.addTableColumn(col)
        }

        // 초기 정렬 — 수정일 내림차순
        tableView.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

        scrollView.documentView = tableView
        coord.scrollView = scrollView
        coord.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.store = store
        coord.refreshIfNeeded()
    }
}

// MARK: - Column Definition

struct ListColumnDefinition {
    let id: String
    let title: String
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
    let hiddenByDefault: Bool

    static let allColumns: [ListColumnDefinition] = [
        .init(id: "name",       title: "이름",    minWidth: 200, idealWidth: 320, maxWidth: 600, hiddenByDefault: false),
        .init(id: "date",       title: "수정일",  minWidth: 100, idealWidth: 140, maxWidth: 200, hiddenByDefault: false),
        .init(id: "size",       title: "크기",    minWidth: 60,  idealWidth: 80,  maxWidth: 120, hiddenByDefault: false),
        .init(id: "type",       title: "종류",    minWidth: 80,  idealWidth: 110, maxWidth: 160, hiddenByDefault: false),
        .init(id: "rating",     title: "별점",    minWidth: 75,  idealWidth: 85,  maxWidth: 120, hiddenByDefault: false),
        .init(id: "resolution", title: "해상도",  minWidth: 85,  idealWidth: 110, maxWidth: 160, hiddenByDefault: true),
        .init(id: "camera",     title: "카메라",  minWidth: 90,  idealWidth: 130, maxWidth: 220, hiddenByDefault: true),
        .init(id: "lens",       title: "렌즈",    minWidth: 90,  idealWidth: 130, maxWidth: 220, hiddenByDefault: true),
    ]
}

// MARK: - Custom NSTableView (키보드 / 드래그 / 컨텍스트 커스텀 지점)

final class ListTableView: NSTableView {
    weak var coordinator: NativeTableListView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        // 우클릭 시 아래 행 선택으로 전환 + 동적 메뉴 구성
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        return coordinator?.buildContextMenu(forRow: row)
    }

    override func keyDown(with event: NSEvent) {
        if let coord = coordinator, coord.handleKeyDown(event: event) {
            return
        }
        super.keyDown(with: event)
    }
}
