//
//  ContentView.swift
//  NeRFCapture
//
//  Created by Jad Abou-Chakra on 13/7/2022.
//

import SwiftUI
import ARKit
import RealityKit
import UIKit


struct ContentView : View {
    @StateObject private var viewModel: ARViewModel
    @State private var showSheet: Bool = false

    init(viewModel vm: ARViewModel) {
        _viewModel = StateObject(wrappedValue: vm)
    }
    
    var body: some View {
        ZStack{
            ZStack(alignment: .topTrailing) {
                ARViewContainer(viewModel).edgesIgnoringSafeArea(.all)
                VStack() {
                    ZStack() {
                        HStack() {
//                            Button() {
//                                showSheet.toggle()
//                            } label: {
//                                Image(systemName: "gearshape.fill")
//                                    .imageScale(.large)
//                            }
//                            .padding(.leading, 16)
//                            .buttonStyle(.borderless)
//                            .sheet(isPresented: $showSheet) {
//                                VStack() {
//                                    Text("Settings")
//                                    Spacer()
//                                }
//                                .presentationDetents([.medium])
//                            }
//                            Spacer()
                        }
                        HStack() {
                            Spacer()
                            Picker("Mode", selection: $viewModel.appState.appMode) {
                                Text("Local").tag(AppMode.Local)
                                Text("Wi-Fi").tag(AppMode.WiFi)
                                Text("USB").tag(AppMode.USB)
                            }
                            .frame(maxWidth: 280)
                            .padding(0)
                            .pickerStyle(.segmented)
                            .disabled(viewModel.appState.writerState
                                      != .SessionNotStarted)
                            
                            Spacer()
                        }
                    }.padding(8)
                    HStack() {
                        Spacer()
                        
                        VStack(alignment:.leading) {
                            Text("\(viewModel.appState.trackingState)")
                            if case .WiFi = viewModel.appState.appMode {
                                Text("\(viewModel.appState.ddsPeers) Connection(s)")
                            }
                            if case .USB = viewModel.appState.appMode {
                                Text(viewModel.appState.usbClientConnected
                                     ? "USB: streaming \(viewModel.appState.usbFrames)"
                                     : "USB: waiting for Mac")
                            }
                            if case .Local = viewModel.appState.appMode {
                                if case .SessionStarted = viewModel.appState.writerState {
                                    Text("\(viewModel.datasetWriter.currentFrameCounter) Frames")
                                }
                            }

                            if viewModel.appState.supportsDepth {
                                Text("Depth Supported")
                            }
                        }.padding()
                    }
                }
            }
            VStack {
                Spacer()
                HStack(spacing: 20) {
                    if case .WiFi = viewModel.appState.appMode {
                        Spacer()
                        Button(action: {
                            viewModel.resetWorldOrigin()
                        }) {
                            Text("Reset")
                                .padding(.horizontal, 20)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        Button(action: {
                            if let frame = viewModel.session?.currentFrame {
                                viewModel.ddsWriter.writeFrameToTopic(frame: frame)
                            }
                        }) {
                            Text("Send")
                                .padding(.horizontal, 20)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                    if case .USB = viewModel.appState.appMode {
                        Spacer()
                        Button(action: {
                            viewModel.resetWorldOrigin()
                        }) {
                            Text("Reset")
                                .padding(.horizontal, 20)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        // Streaming is automatic while a Mac is connected over USB.
                        Text(viewModel.appState.usbClientConnected ? "● LIVE" : "○ waiting")
                            .foregroundColor(viewModel.appState.usbClientConnected ? .red : .secondary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 5)
                    }
                    if case .Local = viewModel.appState.appMode {
                        if viewModel.appState.writerState == .SessionNotStarted {
                            Spacer()
                            
                            Button(action: {
                                viewModel.resetWorldOrigin()
                            }) {
                                Text("Reset")
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            
                            Button(action: {
                                do {
                                    try viewModel.datasetWriter.initializeProject()
                                }
                                catch {
                                    print("\(error)")
                                }
                            }) {
                                Text("Start")
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                        }
                        
                        if viewModel.appState.writerState == .SessionStarted {
                            Spacer()
                            Button(action: {
                                viewModel.datasetWriter.finalizeProject()
                            }) {
                                Text("End")
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            // Continuous recording runs automatically between
                            // Start and End — no per-frame tap. Just a status pill.
                            Text("● REC")
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 5)
                        }
                    }
                }
                .padding()
            }
            .preferredColorScheme(.dark)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            // Returning to the foreground re-arms the USB listener so the Mac
            // recorder can connect regardless of launch order — no swipe-kill.
            viewModel.onForeground()
        }
    }
}

#if DEBUG
struct ContentView_Previews : PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ARViewModel(datasetWriter: DatasetWriter(), ddsWriter: DDSWriter()))
            .previewInterfaceOrientation(.portrait)
    }
}
#endif
