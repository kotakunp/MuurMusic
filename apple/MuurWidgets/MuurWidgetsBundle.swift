import WidgetKit
import SwiftUI

@main
struct MuurWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        QueueWidget()
        ResumeWidget()
        LyricsWidget()
    }
}
