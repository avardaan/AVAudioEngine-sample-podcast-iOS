/// Copyright (c) 2017 Razeware LLC
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
///
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import UIKit
import AVFoundation

class ViewController: UIViewController {

  // MARK: Outlets
  @IBOutlet weak var playPauseButton: UIButton!
  @IBOutlet weak var skipForwardButton: UIButton!
  @IBOutlet weak var skipBackwardButton: UIButton!
  @IBOutlet weak var progressBar: UIProgressView!
  @IBOutlet weak var meterView: UIView!
  @IBOutlet weak var volumeMeterHeight: NSLayoutConstraint!
  @IBOutlet weak var rateSlider: UISlider!
  @IBOutlet weak var rateLabel: UILabel!
  @IBOutlet weak var rateLabelLeading: NSLayoutConstraint!
  @IBOutlet weak var countUpLabel: UILabel!
  @IBOutlet weak var countDownLabel: UILabel!

  // MARK: AVAudio properties
  var engine = AVAudioEngine()
  var player = AVAudioPlayerNode()
  var rateEffect = AVAudioUnitTimePitch()

  var audioFile: AVAudioFile? {
    didSet {
      if let audioFile = audioFile {
        audioLengthSamples = audioFile.length
        audioFormat = audioFile.processingFormat
        audioSampleRate = Float(audioFormat?.sampleRate ?? 44100)
        audioLengthSeconds = Float(audioLengthSamples) / audioSampleRate
      }
    }
  }
  var audioFileURL: URL? {
    didSet {
      if let audioFileURL = audioFileURL {
        audioFile = try? AVAudioFile(forReading: audioFileURL)
      }
    }
  }
  var audioBuffer: AVAudioPCMBuffer?

  // MARK: other properties
  var audioFormat: AVAudioFormat?
  var audioSampleRate: Float = 0
  var audioLengthSeconds: Float = 0
  var audioLengthSamples: AVAudioFramePosition = 0
  var needsFileScheduled = true
  let rateSliderValues: [Float] = [0.5, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
  var rateValue: Float = 1.0 {
    didSet {
      rateEffect.rate = rateValue
      updateRateLabel()
    }
  }
  var updater: CADisplayLink?
  var currentFrame: AVAudioFramePosition {
    guard
      // player.lastRenderTime returns the time in reference to engine start time. If engine is not running, lastRenderTime returns nil
      let lastRenderTime = player.lastRenderTime,
    // player.playerTime(forNodeTime:) converts lastRenderTime to time relative to player start time. If player is not playing, then playerTime returns nil
    let playerTime = player.playerTime(forNodeTime: lastRenderTime)
      else {
        return 0
    }
    return playerTime.sampleTime
    
  }
  var skipFrame: AVAudioFramePosition = 0
  var currentPosition: AVAudioFramePosition = 0
  let pauseImageHeight: Float = 26.0
  let minDb: Float = -80.0

  enum TimeConstant {
    static let secsPerMin = 60
    static let secsPerHour = TimeConstant.secsPerMin * 60
  }

  // MARK: - ViewController lifecycle
  //
  override func viewDidLoad() {
    super.viewDidLoad()

    setupRateSlider()
    countUpLabel.text = formatted(time: 0)
    countDownLabel.text = formatted(time: audioLengthSeconds)
    setupAudio()
    
    // update display
    updater = CADisplayLink(target: self, selector: #selector(updateUI))
    updater?.add(to: .current, forMode: .defaultRunLoopMode)
    updater?.isPaused = true
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    updateRateLabel()
  }
}

// MARK: - Actions
//
extension ViewController {
  @IBAction func didChangeRateValue(_ sender: UISlider) {
    let index = round(sender.value)
    rateSlider.setValue(Float(index), animated: false)
    rateValue = rateSliderValues[Int(index)]
  }

  @IBAction func playTapped(_ sender: UIButton) {
    // toggle play pause button
    sender.isSelected = !sender.isSelected
    // Use player.isPlaying to determine if the player currently playing. If so, pause it; if not, play. You also check needsFileScheduled and reschedule the file if required
    if player.isPlaying {
      disconnectVolumeTap()
      // pause CADisplay
      updater?.isPaused = true
      player.pause()
    } else {
      // check if it needs rescheduling before playing
      if needsFileScheduled {
        needsFileScheduled = false
        scheduleAudioFile()
      }
      connectVolumeTap()
      // start CADisplay
      updater?.isPaused = false
      player.play()
    }
  }

  @IBAction func plus10Tapped(_ sender: UIButton) {
    guard let _ = player.engine else { return }
    seek(to: 10.0)
  }

  @IBAction func minus10Tapped(_ sender: UIButton) {
    guard let _ = player.engine else { return }
    needsFileScheduled = false
    seek(to: -10.0)
  }

  @objc func updateUI() {
    // The property skipFrame is an offset added to or subtracted from currentFrame, initially set to zero. Make sure currentPosition doesn’t fall outside the range of the file
    currentPosition = currentFrame + skipFrame
    currentPosition = max(currentPosition, 0)
    currentPosition = min(currentPosition, audioLengthSamples)
    // get current progress fraction
    progressBar.progress = Float(currentPosition)/Float(audioLengthSamples)
    // get current position in audio file in seconds
    let time = Float(currentPosition)/audioSampleRate
    // set left label time text using format helper
    countUpLabel.text = formatted(time: time)
    // set right label
    countDownLabel.text = formatted(time: audioLengthSeconds - time)
    // if reached end of audio file
    if currentPosition >= audioLengthSamples {
      player.stop()
      updater?.isPaused = true
      playPauseButton.isSelected = false
      disconnectVolumeTap()
    }
  }
}

// MARK: - Display related
//
extension ViewController {
  func setupRateSlider() {
    let numSteps = rateSliderValues.count-1
    rateSlider.minimumValue = 0
    rateSlider.maximumValue = Float(numSteps)
    rateSlider.isContinuous = true
    rateSlider.setValue(1.0, animated: false)
    rateValue = 1.0
    updateRateLabel()
  }

  func updateRateLabel() {
    rateLabel.text = "\(rateValue)x"
    let trackRect = rateSlider.trackRect(forBounds: rateSlider.bounds)
    let thumbRect = rateSlider.thumbRect(forBounds: rateSlider.bounds , trackRect: trackRect, value: rateSlider.value)
    let x = thumbRect.origin.x + thumbRect.width/2 - rateLabel.frame.width/2
    rateLabelLeading.constant = x
  }

  func formatted(time: Float) -> String {
    var secs = Int(ceil(time))
    var hours = 0
    var mins = 0

    if secs > TimeConstant.secsPerHour {
      hours = secs / TimeConstant.secsPerHour
      secs -= hours * TimeConstant.secsPerHour
    }

    if secs > TimeConstant.secsPerMin {
      mins = secs / TimeConstant.secsPerMin
      secs -= mins * TimeConstant.secsPerMin
    }

    var formattedString = ""
    if hours > 0 {
      formattedString = "\(String(format: "%02d", hours)):"
    }
    formattedString += "\(String(format: "%02d", mins)):\(String(format: "%02d", secs))"
    return formattedString
  }
}

// MARK: - Audio
//
extension ViewController {
  func setupAudio() {
    // 1
    // local url of audio file
    audioFileURL = Bundle.main.url(forResource: "Intro", withExtension: "mp4")
    // 2
    // attach player node ro audio engine
    engine.attach(player)
    // connect audio engine to mainMixerNode
    engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
    // prepare to play engine
    engine.prepare()
    // start engine in a try catch block
    do {
      try engine.start()
    } catch let err {
      print(err.localizedDescription)
    }
  }

  func scheduleAudioFile() {
    //
    guard let audioFile = audioFile else { return }
    skipFrame = 0
    player.scheduleFile(audioFile, at: nil) {
      [weak self] in self?.needsFileScheduled = true
    }
    
  }

  func connectVolumeTap() {
  }

  func disconnectVolumeTap() {
  }

  func seek(to time: Float) {
  }

}
