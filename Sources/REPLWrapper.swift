//
//  REPLWrapper.swift
//  iSwiftCore
//
//  Created by Jin Wang on 24/02/2016.
//  Copyright © 2016 Uthoft. All rights reserved.
//

import Foundation
import Dispatch

enum REPLState {
    case prompt
    case input
    case output
}

class Disposable {
    func dispose() {
        
    }
}

class Observable<T> {
    private var observers: [(T) -> Void] = []
    private var curValue: T
    
    init(_ initValue: T) {
        curValue = initValue
    }
    
    func next(_ nextValue: T) {
        curValue = nextValue
        
        Logger.debug.print("Next observale...")
        
        for observer in observers {
            observer(curValue)
        }
    }
    
    func observeNew(_ block: @escaping (T) -> Void) -> Disposable {
        Logger.debug.print("observale New...")
        
        observers.append(block)
        return Disposable()
    }
}

class REPLWrapper: NSObject {
    fileprivate let command: String
    fileprivate var prompt: String
    fileprivate var continuePrompt: String
    fileprivate var lastOutput: String = ""
    fileprivate var consoleOutput = Observable<String>("")
    fileprivate var currentTask: Shell!
    
    fileprivate let runModes = [RunLoopMode.defaultRunLoopMode]
    
    init(command: String, prompt: String, continuePrompt: String) throws {
        self.command = command
        self.prompt = prompt
        self.continuePrompt = continuePrompt
        
        super.init()
        
        try launchTaskInBackground()
    }
    
    func didReceivedData(_ notification: Notification) {
        let data = currentTask.availableData
        
        Logger.debug.print("Get notification...")
        
        guard let dataStr = String(data: data, encoding: .utf8) else { return }
        
        Logger.debug.print("Received data...\(dataStr)")
        
        // For every data the console gives, it can be a new prompt or a continue prompt or an actual output.
        // We'll need to deal with it accordingly.
        if dataStr.match(prompt, options: [.anchorsMatchLines]) {
            // It's a new prompt.
        } else if dataStr.match(continuePrompt, options: [.anchorsMatchLines]) {
            // It's a continue prompt. It means the console is expecting more data.
        } else {
            // It's a raw output.
        }
        
        // Sometimes, the output will contain multiline string. We can't deal with them once. We
        // need to separater them, so that the prompt is dealt in time and the raw output will be captured.
        // FIXME: On Linux, dataStr.components(separatedBy: CharacterSet.newlines) will fail when dataStr is "\r\n"
        let lines = dataStr.components(separatedBy: "\r\n")
        
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            
            Logger.debug.print("Received data line...\(line)")
            
            // Don't remember to add a new line to compensate the loss of the non last line.
            if index == lines.count - 1 && !dataStr.hasSuffix("\n") {
                consoleOutput.next(line)
            } else {
                consoleOutput.next("\(line)\n")
            }
        }
        
        currentTask.waitForDataInBackgroundAndNotify(forModes: runModes)
    }
    
    func taskDidTerminated(_ notification: Notification) {
    }
    
    // The command might be a multiline command.
    func runCommand(_ cmd: String) -> String {
        // Clear the previous output.
        var currentOutput = ""
        
        Logger.debug.print("Running command...\(cmd)")
        
        // We'll observe the output stream and make sure all non-prompts gets recorded into output.
        
        for line in cmd.components(separatedBy: CharacterSet.newlines) {
            // Send out this line for execution.
            sendLine(line)
            
            // For each line, the console will either give back
            // an output (might empty) + an prompt or an continue
            // prompt.
            expect([prompt, continuePrompt]) { output in
                currentOutput += output
            }
        }
        
        lastOutput = currentOutput
        
        // It doesn't matter whether there's any output or not.
        // If the command triggered no output then we'll just return
        // empty string.
        return lastOutput
    }
    
    func shutdown(_ restart: Bool) throws {
        // For now, we just terminate it forcely. We should probably
        // use :quit in the future.
        currentTask.terminate()
        
        if restart {
            try launchTaskInBackground()
        }
    }
    
    fileprivate func launchTaskInBackground() throws {
        DispatchQueue.global(qos: .default).async { [unowned self] in
            do {
                try self.launchTask()
            } catch let e {
                Logger.critical.print(e)
            }
        }
        
        expect([prompt])
    }
    
    fileprivate func launchTask() throws {
        currentTask = Shell()
        currentTask.launchPath = command
        
        #if os(Linux)
            NotificationCenter.default.addObserver(forName: Shell.dataAvailableNotification, object: nil, queue: nil) {
                self.didReceivedData($0)
            }
        #else
            NotificationCenter.default.addObserver(self, selector: #selector(REPLWrapper.didReceivedData(_:)),
                                                   name: Shell.dataAvailableNotification, object: nil)
        #endif
        
        currentTask.waitForDataInBackgroundAndNotify(forModes: runModes)
        
        #if os(Linux)
            NotificationCenter.default.addObserver(forName: Shell.didTerminateNotification, object: nil, queue: nil) {
                self.taskDidTerminated($0)
            }
        #else
            NotificationCenter.default.addObserver(self, selector: #selector(REPLWrapper.taskDidTerminated(_:)),
                                                   name: Shell.didTerminateNotification, object: nil)
        #endif
        
        try currentTask.launch()
        
        currentTask.waitUntilExit()
    }
    
    private func sendLine(_ code: String) {
        // Get rid of the new line stuff which make no sense.
        var trimmedLine = code.trim()
        
        // Only one new line character is needed. And we need
        // this new line if the trimmed code is empty.
        trimmedLine += "\n"
        
        if let codeData = trimmedLine.data(using: String.Encoding.utf8) {
            currentTask.writeWith(codeData)
        }
    }
    
    private func expect(_ patterns: [String], otherHandler: @escaping (String) -> Void = { _ in }) {
        let promptSemaphore = DispatchSemaphore(value: 0)
        
        let dispose = consoleOutput.observeNew {(output) -> Void in
            Logger.debug.print("Console output \(output)")
            
            for pattern in patterns where output.match(pattern) {
                promptSemaphore.signal()
                return
            }
            otherHandler(output)
        }
        
        promptSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        Logger.debug.print("Expect passed...")
        
        dispose.dispose()
    }
}
