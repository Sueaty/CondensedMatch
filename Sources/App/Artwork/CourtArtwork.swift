//
//  CourtArtwork.swift
//  RallyCut
//
//  Created by 조수정 on 10/8/26.
//

import SwiftUI
struct CourtArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let courtWidth = min(w * 0.68, h * 0.62 * (78.0 / 36.0))
            let courtHeight = courtWidth * (36.0 / 78.0)
            let left = (w - courtWidth) / 2
            let right = left + courtWidth
            let top = (h - courtHeight) / 2
            let bottom = top + courtHeight
            let singlesTop = top + courtHeight * 0.125
            let singlesBottom = bottom - courtHeight * 0.125
            let leftServiceLine = left + courtWidth * (21.0 / 78.0)
            let rightServiceLine = right - courtWidth * (21.0 / 78.0)
            
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(MatchStyle.ink)
                
                Path { path in
                    path.addRect(CGRect(x: left, y: top, width: right - left, height: bottom - top))
                    path.move(to: CGPoint(x: left, y: singlesTop)); path.addLine(to: CGPoint(x: right, y: singlesTop))
                    path.move(to: CGPoint(x: left, y: singlesBottom)); path.addLine(to: CGPoint(x: right, y: singlesBottom))
                    path.move(to: CGPoint(x: leftServiceLine, y: singlesTop)); path.addLine(to: CGPoint(x: leftServiceLine, y: singlesBottom))
                    path.move(to: CGPoint(x: rightServiceLine, y: singlesTop)); path.addLine(to: CGPoint(x: rightServiceLine, y: singlesBottom))
                    path.move(to: CGPoint(x: leftServiceLine, y: h / 2)); path.addLine(to: CGPoint(x: rightServiceLine, y: h / 2))
                    path.move(to: CGPoint(x: left, y: h / 2)); path.addLine(to: CGPoint(x: left + 5, y: h / 2))
                    path.move(to: CGPoint(x: right, y: h / 2)); path.addLine(to: CGPoint(x: right - 5, y: h / 2))
                }
                .stroke(.white.opacity(0.48), lineWidth: 1)
                
                Path { path in
                    path.move(to: CGPoint(x: w / 2, y: top))
                    path.addLine(to: CGPoint(x: w / 2, y: bottom))
                }
                .stroke(.white.opacity(0.75), lineWidth: 2)
                
                Path { path in
                    path.move(to: CGPoint(x: left + courtWidth * 0.14, y: singlesBottom))
                    path.addQuadCurve(
                        to: CGPoint(x: right - courtWidth * 0.14, y: singlesTop),
                        control: CGPoint(x: w / 2, y: h / 2 - courtHeight * 0.18)
                    )
                }
                .stroke(MatchStyle.lime.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6]))
                
                Circle()
                    .fill(MatchStyle.lime)
                    .frame(width: 15, height: 15)
                    .position(x: right - courtWidth * 0.14, y: singlesTop)
                
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .position(x: left + courtWidth * 0.14, y: singlesBottom)
                
                VStack {
                    Spacer()
                    
                    HStack {
                        Text("EVERY RALLY. LESS WAITING.")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .tracking(2)
                        Spacer()
                    }
                }
                .padding(18)
                .foregroundStyle(.white.opacity(0.65))
            }
        }
        .accessibilityHidden(true)
    }
}
