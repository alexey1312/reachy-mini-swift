import Foundation

/// The three lines of a `confirmationDialog`, built by the model that knows what is
/// about to happen rather than by the view showing it.
///
/// A type rather than a tuple, and its keys deliberately do not echo the button that
/// opened it: the catalogue derives a Swift symbol per key, and two keys differing
/// only in punctuation — `Uninstall all apps` against `Uninstall all apps?` —
/// collide as a hard `xcstringstool` build error. Keeping the copy on the model is
/// also what lets a test read it: the dialog itself captures as nothing, so the
/// words are the one part of it a reference image cannot cover.
struct Confirmation {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let confirm: LocalizedStringResource
}
