//
//  ViewController.swift
//  HackQ
//
//  Created by Gordon on 2/19/18.
//  Copyright © 2018 Gordon Jacobs. All rights reserved.
//

import Cocoa
import Alamofire
import SwiftyJSON
import SwiftWebSocket

protocol DiscordTriviaNotifyDelegate: class {
    func didResetRound()
}

class DiscordTriviaNotifier {
    weak var delegate: DiscordTriviaNotifyDelegate?
    
    init() {}
    
    func notifyRoundReset() {
        print("Round has been reset")
        delegate?.didResetRound()
    }
}

class ViewController: NSViewController, NSTextFieldDelegate, DiscordTriviaDelegate {
    @IBOutlet private weak var gameAndQuestionsInfoLabel: NSTextField!
    @IBOutlet private weak var nextGameInfoLabel: NSTextField!
    @IBOutlet private weak var fixedQuestionLabel: NSTextField!
    @IBOutlet private weak var fixedAnswer1Label: NSTextField!
    @IBOutlet private weak var fixedAnswer2Label: NSTextField!
    @IBOutlet private weak var fixedAnswer3Label: NSTextField!
    @IBOutlet private weak var fixedBestAnswerLabel: NSTextField!
    @IBOutlet private weak var questionLabel: NSTextField!
    @IBOutlet private weak var answer1Label: NSTextField!
    @IBOutlet private weak var answer2Label: NSTextField!
    @IBOutlet private weak var answer3Label: NSTextField!
    @IBOutlet private weak var bestAnswerLabel: NSTextField!
    
    private var fixedLabels: [NSTextField] = []
    private var answerLabels: [NSTextField] = []
    
    private let hqheaders: HTTPHeaders = [
        "x-hq-client": Config.hqClient,
        "Authorization": Config.bearerToken,
        "x-hq-stk": "MQ==",
        "Host": Config.hostURL,
        "Connection": "Keep-Alive",
        "Accept-Encoding": "gzip",
        "User-Agent": "okhttp/3.8.0"
    ]
    
    private var socketUrl = "https://socketUrl"
    
    private var isGameLive: Bool {
        return socketUrl.hasPrefix("wss")
    }
    
    private var discordTrivia: DiscordTrivia?
    private var currentQuestion: Question?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        fixedLabels = [fixedQuestionLabel, fixedAnswer1Label, fixedAnswer2Label, fixedAnswer3Label, fixedBestAnswerLabel]
        answerLabels = [answer1Label, answer2Label, answer3Label]
        
        SiteEncoding.addGoogleAPICredentials(apiKeys: [Config.googleAPIKey],
                                             searchEngineID: Config.googleSearchEngineID)

        updateQuestionsAndAnswersLabels()

        getSocketURL()
        
        discordTrivia = DiscordTrivia(triviaShow: .hq)
        discordTrivia?.delegate = self
    }
    
    func getSocketURL() {
        Alamofire.request("\(Config.hostFullURL)\(Config.userID)", headers: hqheaders).responseJSON { response in
            if let result = response.result.value {
                let json = JSON(result)
                let broadcast = json["broadcast"]
                
                if (broadcast != JSON.null) {
                    print("Game is live!")
                    self.showQuestionsAndAnswers()
                    
                    self.socketUrl = JSON(broadcast)["socketUrl"].stringValue
                    print(self.socketUrl)
                    print("-----")
                    
                    self.socketUrl = self.socketUrl.replacingOccurrences(of: "https", with: "wss")
                    print(self.socketUrl)
                    print("-----")
                } else {
                    print("No socket available. The game is not live.")
                    let prize = json["nextShowPrize"].stringValue
                    let showTime = Date(RFC3339FormattedString: json["nextShowTime"].stringValue)!
                    
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    formatter.doesRelativeDateFormatting = true
                    
                    let prettyShowTime = formatter.string(from: showTime)
                    
                    self.nextGameInfoLabel.stringValue = "\(prettyShowTime)\n\(prize) prize"
                    self.showNextGameInfo(true)
                    
                    return
                }
            }
            
            self.openWebSocket()
        }
    }
    
    func openWebSocket() {
        var request = URLRequest(url: URL(string: socketUrl)!)
        request.timeoutInterval = 5
        request.addValue(Config.hqClient, forHTTPHeaderField: "x-hq-client")
        request.addValue(Config.bearerToken, forHTTPHeaderField: "Authorization")
        request.addValue("MQ==", forHTTPHeaderField: "x-hq-stk")
        request.addValue(Config.hostURL, forHTTPHeaderField: "Host")
        request.addValue("Keep-Alive", forHTTPHeaderField: "Connection")
        request.addValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.addValue("okhttp/3.8.0", forHTTPHeaderField: "User-Agent")
        let ws = WebSocket(request: request)
        
        ws.event.open = {
            print("Opened web socket.")
            print("-----")
        }
        
        ws.event.error = { error in
            print("Error: \(error)")
            print("-----")
        }
        
        ws.event.message = { message in
            if let receivedString = message as? String,
                let data = receivedString.data(using: .utf8),
                let receivedAsJSON = try! JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = receivedAsJSON["type"] as? String {
                
                if (type == "question") {
                    self.discordTrivia?.discordNotifier.notifyRoundReset()
                    self.currentQuestion = Question(json: JSON(receivedAsJSON))
                    print(String(describing: self.currentQuestion!))
                    
                    self.getMatches()
                
                    self.updateQuestionsAndAnswersLabels()
                }
                
                if (type == "broadcastEnded") {
                    self.openWebSocket()
                }
            }
        }
    }
    
    @IBAction func openSocket(_ sender: Any) {
        getSocketURL()
        openWebSocket()
    }
    
    ///Retrieves the correct answer
    private func getMatches()
    {
        let answers = currentQuestion!.answers.compactMap { ($0.id, $0.text ) }
        AnswerController.answer(for: currentQuestion!.text, answers: answers) { ans in
            self.currentQuestion?.hasSearchCompleted = true
            ans.forEach { self.currentQuestion?.answers[$0.id]?.updateProbability(prob: $0.probability) }
            
            self.updateQuestionsAndAnswersLabels()
        }
    }
    
    func showNextGameInfo(_ state: Bool) {
        gameAndQuestionsInfoLabel.isHidden = false
        nextGameInfoLabel.isHidden = !state
    }
    
    func showQuestionsAndAnswers() {
        NSAnimationContext.runAnimationGroup({ _ in
            NSAnimationContext.current.duration = 2.0
            self.nextGameInfoLabel.animator().alphaValue = 0.0
            self.gameAndQuestionsInfoLabel.animator().alphaValue = 0.0
        }, completionHandler: {
            self.showNextGameInfo(false)
            self.updateGameAndQuestionsInfoLabel()
            self.gameAndQuestionsInfoLabel.animator().alphaValue = 1.0
            
            self.questionLabel.isHidden = !self.questionLabel.isHidden
            self.fixedLabels.forEach { $0.isHidden = !$0.isHidden }
            self.answerLabels.forEach { $0.isHidden = !$0.isHidden }
            self.bestAnswerLabel.isHidden = !self.bestAnswerLabel.isHidden
        })
    }
    
    func updateGameAndQuestionsInfoLabel() {
        if isGameLive {
            gameAndQuestionsInfoLabel.stringValue = currentQuestion != nil ?
                "QUESTION \(currentQuestion!.number) OF \(currentQuestion!.totalCount)" :
            "WAITING FOR QUESTIONS"
        } else {
            gameAndQuestionsInfoLabel.stringValue = "NEXT GAME"
        }
    }
    
    func updateQuestionsAndAnswersLabels() {
        updateGameAndQuestionsInfoLabel()
        
        if let answers = currentQuestion?.answers, let completed = currentQuestion?.hasSearchCompleted, completed {
            let formattedAnswers = answers.compactMap { String(describing: $0) }
            print(formattedAnswers)
            
            for (index, label) in answerLabels.enumerated() {
                label.stringValue = formattedAnswers[index]
            }
            
            bestAnswerLabel.stringValue = answers.highest!.text + " (\(answers.highest!.probability.rounded)% confidence)"
        } else {
            // New question, not searched yet
            questionLabel.stringValue = currentQuestion?.text ?? "Question"
            
            for (index, label) in answerLabels.enumerated() {
                label.stringValue = currentQuestion?.answers[index].text ?? "Answer \(index+1)"
            }
            
            bestAnswerLabel.stringValue = "Best Answer"
        }
    }
    
    func didUpdateVotes(votes: DiscordConfidence) {
        // update discord labels with votes
    }
    
}
