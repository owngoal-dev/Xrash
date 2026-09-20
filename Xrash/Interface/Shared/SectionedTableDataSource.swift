import UIKit

/// `UITableViewDiffableDataSource` that still answers the plain header and
/// footer titles, and lets a table be swiped.
///
/// `titleForHeaderInSection` is a *data source* method, so a grouped screen
/// that moves to a snapshot silently loses every section title unless
/// something takes them over. Subclassing is the documented way, and one
/// subclass here is the alternative to one per screen. The closures are asked
/// per draw and answer from the controller's own state, which is what keeps a
/// title that counts something honest without the count becoming a second
/// thing to keep in the snapshot.
final class SectionedTableDataSource<Section: Hashable, Item: Hashable>:
    UITableViewDiffableDataSource<Section, Item>
{
    var header: ((Section) -> String?)?
    var footer: ((Section) -> String?)?
    /// Swipe actions only appear on rows the data source calls editable, and
    /// a diffable data source says no unless it is told otherwise.
    var isEditable = false

    override func tableView(_: UITableView, titleForHeaderInSection index: Int) -> String? {
        sectionIdentifier(for: index).flatMap { header?($0) }
    }

    override func tableView(_: UITableView, titleForFooterInSection index: Int) -> String? {
        sectionIdentifier(for: index).flatMap { footer?($0) }
    }

    override func tableView(_: UITableView, canEditRowAt _: IndexPath) -> Bool {
        isEditable
    }
}
