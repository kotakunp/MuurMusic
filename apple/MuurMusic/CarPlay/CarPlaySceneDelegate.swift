#if os(iOS)
#if canImport(CarPlay)
import CarPlay
import UIKit
import MuurCore
import MuurAudio

/// CarPlay: a simple list of Recently Played, Playlists and quick actions.
/// Compiles without the CarPlay entitlement; the scene only activates when the
/// `carplay-audio` entitlement is present (see BUILD.md).
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var rootTemplate: CPListTemplate?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let root = makeRootTemplate()
        rootTemplate = root
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        reload()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        rootTemplate = nil
    }

    private func makeRootTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "MuurMusic", sections: [])
        template.tabImage = UIImage(named: "BrandMark")
        return template
    }

    private func reload() {
        Task {
            await buildSections()
        }
    }

    private func buildSections() async {
        guard let rootTemplate else { return }
        let model = AppModel.requireShared()

        var sections: [CPListSection] = []

        // Actions
        let shuffleItem = CPListItem(text: "Shuffle All Songs", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffleItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.shuffleAll()
                completion()
            }
        }
        let resumeItem = CPListItem(text: "Resume", detailText: "Continue your last session", image: UIImage(systemName: "play.fill"))
        resumeItem.handler = { _, completion in
            model.player.resumeRestoredQueue()
            completion()
        }
        sections.append(CPListSection(items: [shuffleItem, resumeItem], header: "Actions", sectionIndexTitle: nil))

        // Recently played
        do {
            let recent = try await model.environment.database.read { db in
                try LibraryQueries.recentlyPlayed(db, limit: 24)
            }
            if !recent.isEmpty {
                let cache = model.environment.artwork
                let artworkData = await Task.detached(priority: .utility) { () -> [Data?] in
                    recent.map { $0.artworkKey.flatMap { cache.thumbnailData(for: $0, size: 120) } }
                }.value
                let items = zip(recent, artworkData).map { track, data -> CPListItem in
                    let image = data.flatMap { UIImage(data: $0) }
                    let item = CPListItem(text: track.displayTitle, detailText: track.displayArtist, image: image)
                    item.handler = { _, completion in
                        model.play([track])
                        completion()
                    }
                    return item
                }
                sections.append(CPListSection(items: items, header: "Recently Played", sectionIndexTitle: nil))
            }
        } catch {}

        // Playlists
        do {
            let playlists = try await model.environment.playlists.playlists()
            if !playlists.isEmpty {
                let items = playlists.prefix(24).map { playlist -> CPListItem in
                    let item = CPListItem(text: playlist.name, detailText: playlist.isSmart ? "Smart playlist" : nil)
                    item.handler = { [weak self] _, completion in
                        Task { @MainActor in
                            await self?.playPlaylist(playlist)
                            completion()
                        }
                    }
                    return item
                }
                sections.append(CPListSection(items: Array(items), header: "Playlists", sectionIndexTitle: nil))
            }
        } catch {}

        rootTemplate.updateSections(sections)
    }

    private func shuffleAll() async {
        let model = AppModel.requireShared()
        do {
            let tracks = try await model.environment.database.read { db in
                try LibraryQueries.randomTracks(db, limit: 200)
            }
            model.play(tracks)
        } catch {
            model.showError(error)
        }
    }

    private func playPlaylist(_ playlist: Playlist) async {
        guard let id = playlist.id else { return }
        let model = AppModel.requireShared()
        do {
            if let contents = try await model.environment.playlists.contents(of: id) {
                model.play(contents.tracks)
            }
        } catch {
            model.showError(error)
        }
    }
}
#endif
#endif
