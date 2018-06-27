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
    // attach rateEffect
    engine.attach(rateEffect)
    // connect player to rateEffect
    engine.connect(player, to: rateEffect, format: audioFormat)
    // connect rateEffect to mainMixerNode
    engine.connect(rateEffect, to: engine.mainMixerNode, format: audioFormat)
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
    // get audio data format for main mixer's output node
    let format = engine.mainMixerNode.outputFormat(forBus: 0)
    // install an output puller on the bus, that pulls buffer of size 1024
    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { (buffer, when) in
      guard
        let channelData = buffer.floatChannelData,
        let updater = self.updater
      else { return }
      // buffer.floatChannelData gives you an array of pointers to each sample’s data. channelDataValue is an array of UnsafeMutablePointer<Float>
      let channelDataValue = channelData.pointee
      // I do not fully understand this, like...what
      let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map{ channelDataValue[$0] }
      // calculate root mean square
      let rms = sqrt(channelDataValueArray.map{$0 * $0}.reduce(0, +) / Float(buffer.frameLength))
      // convert rms to decibels
      let avgPower = 20 * log10(rms)
      // scale to value suitable for VU meter
      let meterLevel = self.scaledPower(power: avgPower)
      // run thread to do something
      DispatchQueue.main.async {
        self.volumeMeterHeight.constant = !updater.isPaused ? CGFloat(min((meterLevel * self.pauseImageHeight), self.pauseImageHeight)) : 0.0
      }
    }
  }
  
  // helper method to scale power
  // scaledPower(power:) converts the negative power decibel value to a positive value that adjusts the volumeMeterHeight.constant value above
  func scaledPower(power: Float) -> Float {
    // check if power is a finite value
    guard power.isFinite else { return 0.0 }
    // dB range is -80 to 0 dB. Power is 0.0 to 1.0. Scale accordingly
    if power < minDb {
      return 0.0
    } else if power >= 1.0 {
      return 1.0
    } else {
      // return scaled
      // fabs is float absolute
      return ( (fabs(minDb) - fabs(power)) / fabs(minDb) )
    }
  }

  func disconnectVolumeTap() {
    // AVAudioEngine only allows one tap per bus. Remove it when not in use
    engine.mainMixerNode.removeTap(onBus: 0)
    volumeMeterHeight.constant = 0.0
  }

  func seek(to time: Float) {
    guard
      let audioFile = audioFile,
      let updater = updater
      else { return }
    
    // get current frame using time * audioSamples, then make sure it is within start and end of audiofile
    skipFrame = currentPosition + AVAudioFramePosition(time * audioSampleRate)
    skipFrame = max(skipFrame, 0)
    skipFrame = min(skipFrame, audioLengthSamples)
    currentPosition = skipFrame
    
    // stop player and clear schedules
    player.stop()
    //
    if currentPosition < audioLengthSamples {
      updateUI()
      needsFileScheduled = false
      // what, wtf is weak self...??
      // player.scheduleSegment(_:startingFrame:frameCount:at:) schedules playback starting at skipFrame position of audioFile. frameCount is the number of frames to play. You want to play to the end of file, so set it to audioLengthSamples - skipFrame. Finally, at: nil specifies to start playback immediately instead of at some time in the future
      player.scheduleSegment(audioFile, startingFrame: skipFrame, frameCount: AVAudioFrameCount(audioLengthSamples - skipFrame), at: nil) { [weak self] in self?.needsFileScheduled = true }
      //
      if !updater.isPaused {
        player.play()
      }
    }
  }

}
