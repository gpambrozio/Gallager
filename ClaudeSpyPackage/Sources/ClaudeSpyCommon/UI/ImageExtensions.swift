import SwiftUI

public extension Label where Title == Text, Icon == Image {
    init(_ title: any StringProtocol, symbol: Symbols) {
        self.init {
            Text(title)
        } icon: {
            symbol.image
        }
    }
}

public extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text, Actions == EmptyView  {
    init(
        _ title: any StringProtocol,
        symbol: Symbols,
        description: any StringProtocol
    ) {
        self.init {
            SwiftUI.Label(title, symbol: symbol)
        } description: {
            Text(description)
        } actions: {
            EmptyView()
        }
    }
}
