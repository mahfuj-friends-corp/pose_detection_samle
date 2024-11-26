import 'dart:developer';
import 'dart:typed_data';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:path_provider/path_provider.dart';

List<CameraDescription>? cameras;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController _cameraController;
  late PoseDetector _poseDetector;
  List<Pose> _detectedPoses = [];
  bool _isRecording = false;
  bool _isProcessingFrame = false;
  int _frameSkipCount = 0;
  String? _recordedVideoPath;

  @override
  void initState() {
    super.initState();

    _initializeCamera();
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(mode: PoseDetectionMode.stream),
    );

  }



  Future<void> _initializeCamera() async {
    _cameraController = CameraController(
      cameras!.first,
      ResolutionPreset.medium,
      enableAudio: false, // Disable audio for simplicity
    );
    await _cameraController.initialize();
    if (mounted) setState(() {});
    _cameraController.startImageStream(_processCameraFrame);
  }

  Future<void> _processCameraFrame(CameraImage image) async {
    _frameSkipCount++;
    if (_frameSkipCount % 3 != 0 || _isProcessingFrame) return;

    _isProcessingFrame = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image);
      if (inputImage != null) {
        final poses = await _poseDetector.processImage(inputImage);

        setState(() {
          _detectedPoses = poses;
        });
      }
    } catch (e) {
      print('Error processing frame: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<InputImage?> _convertCameraImageToInputImage(CameraImage image) async {
    try {
      if (Platform.isAndroid && image.format.raw != 35) {
        print('Unsupported image format: ${image.format.raw}');
        return null;
      }

      final bytes = _concatenatePlanes(image.planes);
      if (bytes == null) return null;

      final rotation = InputImageRotation.rotation90deg; // Adjust as needed

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      print('Error converting CameraImage to InputImage: $e');
      return null;
    }
  }

  Uint8List? _concatenatePlanes(List<Plane> planes) {
    try {
      final bytes = <int>[];
      for (final plane in planes) {
        bytes.addAll(plane.bytes);
      }
      return Uint8List.fromList(bytes);
    } catch (e) {
      print('Error concatenating planes: $e');
      return null;
    }
  }

  Future<void> _startRecording() async {
    if (!_cameraController.value.isInitialized || _isRecording) return;

    setState(() {
      _isRecording = true;
    });

    // Use the cache directory for temporary storage
    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory('${tempDir.path}/pose_detection/frames');
    final videoFilePath = '${tempDir.path}/pose_detection/recorded_video.mp4';

    // Ensure frames directory exists
    if (!framesDir.existsSync()) {
      framesDir.createSync(recursive: true);
    }

    final stopwatch = Stopwatch()..start(); // Start a timer

    try {
      print("Recording frames...");
      int frameCount = 0;

      while (stopwatch.elapsed.inSeconds < 10) {
        // Take a picture
        final image = await _cameraController.takePicture();
        final framePath = '${framesDir.path}/frame_${frameCount.toString().padLeft(3, '0')}.jpg';
        File(image.path).copySync(framePath);

        print('Saved frame: $framePath'); // Debugging frame saving
        frameCount++;
      }

      stopwatch.stop(); // Stop the timer

      // Debugging: Check saved frames
      final frameFiles = framesDir.listSync();
      print('Frames found: ${frameFiles.map((e) => e.path).join(", ")}');

      print("Combining frames into a video...");

      // FFmpeg command with better quality settings
      final ffmpegCommand = [
        '-framerate', '4', // Match 30 FPS
        '-i', '${framesDir.path}/frame_%03d.jpg', // Input frame sequence
        '-c:v', 'libx264', // Use H.264 codec
        '-crf', '18', // Constant Rate Factor (lower = better quality; range: 0-51)
        '-preset', 'slow', // Slow preset for better compression efficiency
        '-pix_fmt', 'yuv420p', // Standard pixel format for compatibility
        '-b:v', '2M', // Set bitrate to 2 Mbps
        videoFilePath
      ].join(' ');

      await FFmpegKit.executeAsync(ffmpegCommand, (session) async {
        final returnCode = await session.getReturnCode();
        final output = await session.getOutput();
        final logs = await session.getLogsAsString();
        if (ReturnCode.isSuccess(returnCode)) {
          print('Video saved successfully at: $videoFilePath');
          setState(() {
            _recordedVideoPath = videoFilePath;
          });
        } else {
          log('FFmpeg Command: $ffmpegCommand');
          log('FFmpeg Output Path: $videoFilePath');
          log('FFmpeg logs: $logs');
          log('FFmpegKit failed with return code: $returnCode');
          log('FFmpeg error output: $output');
        }
      });
    } catch (e) {
      print('Error during recording: $e');
    } finally {
      setState(() {
        _isRecording = false;
      });
    }
  }







  @override
  Widget build(BuildContext context) {
    if (!_cameraController.value.isInitialized) {
      return Scaffold(
        appBar: AppBar(title: Text("Pose Detection and Recording")),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text("Pose Detection and Recording")),
      body: Stack(
        children: [
          Positioned.fill(
            child: CameraPreview(_cameraController),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: PosePainter(
                _detectedPoses,
                _cameraController.value.previewSize!,
                  InputImageRotation.rotation90deg
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isRecording ? null : _startRecording,
        child: Icon(_isRecording ? Icons.stop : Icons.videocam),
      ),
    );
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _poseDetector.close();
    super.dispose();
  }
}

class PosePainter extends CustomPainter {
  PosePainter(this.poses, this.absoluteImageSize, this.rotation);

  final List<Pose> poses;
  final Size absoluteImageSize;
  final InputImageRotation rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..color = Colors.red;

    final leftPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.yellow;

    final rightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.blueAccent;

    final myPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.purpleAccent;

    final myPaint1 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.deepPurpleAccent;

    final myPaint2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.lightGreen;

    for (final pose in poses) {
      pose.landmarks.forEach(
            (_, landmark) {
          canvas.drawCircle(
            Offset(
              translateX(landmark.x, rotation, size, absoluteImageSize),
              translateY(landmark.y, rotation, size, absoluteImageSize),
            ),
            1,
            paint,
          );
        },
      );

      void paintLine(PoseLandmarkType type1, PoseLandmarkType type2, Paint paintType) {
        final PoseLandmark joint1 = pose.landmarks[type1]!;
        final PoseLandmark joint2 = pose.landmarks[type2]!;
        canvas.drawLine(
          Offset(translateX(joint1.x, rotation, size, absoluteImageSize),
              translateY(joint1.y, rotation, size, absoluteImageSize)),
          Offset(translateX(joint2.x, rotation, size, absoluteImageSize),
              translateY(joint2.y, rotation, size, absoluteImageSize)),
          paintType,
        );
      }

      paintLine(PoseLandmarkType.nose, PoseLandmarkType.leftShoulder, myPaint1);
      paintLine(PoseLandmarkType.nose, PoseLandmarkType.rightShoulder, myPaint1);

      //Draw Shoulder
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder, myPaint);

      //Draw Arms
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow, leftPaint);
      paintLine(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist, rightPaint);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow, rightPaint);
      paintLine(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist, leftPaint);

      //Draw Body
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip, myPaint1);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip, myPaint2);

      //Draw Hip
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.rightHip, myPaint);

      //Draw Legs
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee, leftPaint);
      paintLine(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle, rightPaint);
      paintLine(PoseLandmarkType.leftAnkle, PoseLandmarkType.leftHeel, myPaint);
      paintLine(PoseLandmarkType.leftHeel, PoseLandmarkType.leftFootIndex, myPaint);
      paintLine(PoseLandmarkType.leftFootIndex, PoseLandmarkType.leftAnkle, myPaint);


      paintLine(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee, rightPaint);
      paintLine(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle, leftPaint);
      paintLine(PoseLandmarkType.rightAnkle, PoseLandmarkType.rightHeel, myPaint1);
      paintLine(PoseLandmarkType.rightHeel, PoseLandmarkType.rightFootIndex, myPaint1);
      paintLine(PoseLandmarkType.rightFootIndex, PoseLandmarkType.rightAnkle, myPaint1);

    }
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return oldDelegate.absoluteImageSize != absoluteImageSize || oldDelegate.poses != poses;
  }
}



double translateX(double x, InputImageRotation rotation, Size size, Size imageSize) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      return x * size.width / (Platform.isIOS ? imageSize.width : imageSize.height);
    case InputImageRotation.rotation270deg:
      return size.width - x * size.width / (Platform.isIOS ? imageSize.width : imageSize.height);
    default:
      return x * size.width / imageSize.width;
  }
}

double translateY(double y, InputImageRotation rotation, Size size, Size imageSize) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y * size.height / (Platform.isIOS ? imageSize.height : imageSize.width);
    default:
      return y * size.height / imageSize.height;
  }
}

double translateX1({
  required double x,
  required Size canvasSize,
  required Size imageSize,
  required InputImageRotation rotation,
  required CameraLensDirection cameraLensDirection,
}) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      return x * canvasSize.width / (Platform.isIOS ? imageSize.width : imageSize.height);
    case InputImageRotation.rotation270deg:
      return canvasSize.width - x * canvasSize.width / (Platform.isIOS ? imageSize.width : imageSize.height);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      switch (cameraLensDirection) {
        case CameraLensDirection.back:
          return x * canvasSize.width / imageSize.width;
        default:
          return canvasSize.width - x * canvasSize.width / imageSize.width;
      }
  }
}

double translateY1({
  required double y,
  required Size canvasSize,
  required Size imageSize,
  required InputImageRotation rotation,
  required CameraLensDirection cameraLensDirection,
}) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y * canvasSize.height / (Platform.isIOS ? imageSize.height : imageSize.width);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      return y * canvasSize.height / imageSize.height;
  }
}

