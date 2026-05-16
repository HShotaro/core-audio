//
//  ContentView.swift
//  CoreAudioStudy
//
//  Created by shotaro hirano on 2026/05/15.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Step 1: AVAudioEngine の内側を理解する") {
                    Step1View()
                }
                NavigationLink("Step 2: VPIO の内側を理解する") {
                    Step2View()
                }
                NavigationLink("Step 3: RenderCallback で音を鳴らす") {
                    Step3View()
                }
            }
            .navigationTitle("Core Audio Study")
        }
    }
}

#Preview {
    ContentView()
}
