//
//  MatchTypography.swift
//  RallyCut
//
//  Created by 조수정 on 10/10/26.
//

import SwiftUI

enum MatchTypography {
    case brand
    case title
    case title2
    case body
    case caption

    var font: Font {
        switch self {
        case .brand:
            return .system(size: 24, weight: .bold, design: .rounded)
        case .title:
            return .system(size: 44, weight: .regular, design: .serif)
        case .title2:
            return .system(size: 32, weight: .regular, design: .serif)
        case .body:
            return .subheadline
        case .caption:
            return .caption
        }
    }
}

extension View {
    func typography(_ style: MatchTypography) -> some View {
        font(style.font)
    }
}
