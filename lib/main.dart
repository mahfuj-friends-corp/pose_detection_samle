import 'dart:developer';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:image/image.dart' as img;

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
  String? _recordedVideoPath;
  bool _saveVideo = true;
  List<CameraImage> framesList= <CameraImage>[];
  int _remainingSeconds = 5; // For countdown display


  @override
  void initState() {
    super.initState();
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(mode: PoseDetectionMode.stream),
    );
    _initializeCamera();



  }



  Future<void> _initializeCamera() async {
    _cameraController = CameraController(
      cameras!.first,
      ResolutionPreset.high,
      enableAudio: false, // Disable audio for simplicity
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21 // for Android
          : ImageFormatGroup.bgra8888, // for iOS
    );
    await _cameraController.initialize();
    // Set flash mode to off
    await _cameraController.setFlashMode(FlashMode.off);
    await _cameraController.lockCaptureOrientation(DeviceOrientation.portraitUp);
    if (mounted) setState(() {});
    _cameraController.startImageStream((image){
      if(_saveVideo){
         framesList.add(image);
        _processCameraFrame(image);
      }
    });
    _startCountdown();

  }

  void _startCountdown() {
    Future.delayed(const Duration(seconds: 1), () {
      if (_remainingSeconds > 0) {
        setState(() {
          _remainingSeconds--;
        });
        _startCountdown();
      } else {
        _processVideo(); // Automatically call the video processing function
      }
    });
  }


  Future<void> _processCameraFrame(CameraImage image) async {
    if (_isProcessingFrame) return; // Adjust %3 to control processing frequency

    _isProcessingFrame = true;

    try {
      // Step 1: Pose Detection
      final inputImage = await _convertCameraImageToInputImage(image);
      if (inputImage != null) {
        final poses = await _poseDetector.processImage(inputImage);
        setState(() {
          _detectedPoses = poses; // Update detected poses
        });
      }


    } catch (e) {
      print('Error processing camera frame: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  static Future<void> _saveFrameToDisk(SaveFrameArgs args) async {
    final file = File(args.framePath);
    await file.writeAsBytes(args.frameBytes);
    print('Frame saved to: ${args.framePath}');
  }











  Future<Uint8List> _convertCameraImageToJpg(CameraImage image) async {
    try {
      // Convert YUV420 image to RGB
      final imgRgb = _convertYUV420ToImage(image);

      // Encode RGB image to JPG
      final jpgBytes = img.encodeJpg(imgRgb);
      return Uint8List.fromList(jpgBytes);
    } catch (e) {
      print('Error converting image: $e');
      rethrow;
    }
  }




  static img.Image _convertYUV420ToImage(CameraImage image) {
    final width = image.width;
    final height = image.height;

    if (Platform.isAndroid && image.format.group == ImageFormatGroup.nv21) {
      Uint8List yuv420sp = image.planes[0].bytes;
      final outImg = img.Image(height: height, width: width);
      final int frameSize = width * height;

      for (int j = 0, yp = 0; j < height; j++) {
        int uvp = frameSize + (j >> 1) * width, u = 0, v = 0;
        for (int i = 0; i < width; i++, yp++) {
          int y = (0xff & yuv420sp[yp]) - 16;
          if (y < 0) y = 0;
          if ((i & 1) == 0) {
            v = (0xff & yuv420sp[uvp++]) - 128;
            u = (0xff & yuv420sp[uvp++]) - 128;
          }
          int y1192 = 1192 * y;
          int r = (y1192 + 1634 * v);
          int g = (y1192 - 833 * v - 400 * u);
          int b = (y1192 + 2066 * u);

          if (r < 0) r = 0;
          else if (r > 262143) r = 262143;
          if (g < 0) g = 0;
          else if (g > 262143) g = 262143;
          if (b < 0) b = 0;
          else if (b > 262143) b = 262143;

          outImg.setPixelRgba(i, j, ((r << 6) & 0xff0000) >> 16,
              ((g >> 2) & 0xff00) >> 8, (b >> 10) & 0xff, 255);
        }
      }
      return _rotateImage(outImg,cameras![0].sensorOrientation);
    } else if (Platform.isIOS && image.format.group == ImageFormatGroup.bgra8888) {
      final imgBuffer = image.planes[0].bytes;
      final rgbBuffer = Uint8List(width * height * 3);

      for (int i = 0; i < width * height; i++) {
        final b = imgBuffer[i * 4];     // Blue
        final g = imgBuffer[i * 4 + 1]; // Green
        final r = imgBuffer[i * 4 + 2]; // Red
        rgbBuffer[i * 3] = r;
        rgbBuffer[i * 3 + 1] = g;
        rgbBuffer[i * 3 + 2] = b;
      }

      return img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgbBuffer.buffer,
      );
    } else {
      throw Exception('Unsupported platform or image format.');
    }
  }


  static img.Image _rotateImage(img.Image inputImage, int rotation) {
    switch (rotation) {
      case 90:
        return img.copyRotate(inputImage, angle: 90);
      case 180:
        return img.copyRotate(inputImage, angle: 180);
      case 270:
        return img.copyRotate(inputImage, angle: 270);
      default:
        return inputImage;
    }
  }




  Future<InputImage?> _convertCameraImageToInputImage(CameraImage image) async {
    try {


      final bytes = _concatenatePlanes(image.planes);
      if (bytes == null) return null;
      final imageRotation = InputImageRotationValue.fromRawValue(cameras![0].sensorOrientation)
          ?? InputImageRotation.rotation0deg; // Default to 0deg if null

      final inputImageFormat = InputImageFormatValue.fromRawValue(image.format.raw);

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: imageRotation,
          format: inputImageFormat!,
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

  Future<void> _processVideo() async {
    if (!_cameraController.value.isInitialized || _isRecording) return;




    setState(() {
      _saveVideo=false;
      _isRecording = true;
    });

    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory('${tempDir.path}/pose_detection/frames');
    final videoFilePath = '${tempDir.path}/pose_detection/recorded_video.mp4';


    try {
      if (!framesDir.existsSync()) {
        framesDir.createSync(recursive: true);
      }
      for(int i=0;i<framesList.length;i++){
        final jpgBytes = await _convertCameraImageToJpg(framesList[i]);
        final framePath = '${framesDir.path}/frame_${i.toString().padLeft(3, "0")}.jpg';

        _saveFrameToDisk(SaveFrameArgs(jpgBytes, framePath));
      }

      // Step 1: Ensure frames are being saved
      if (!framesDir.existsSync() || framesDir.listSync().isEmpty) {
        throw Exception('No frames available for video generation.');
      }

      final frameFiles = framesDir.listSync();
      log('Frames available for FFmpeg: ${frameFiles.map((file) => file.path).toList()}');
      log('Frames available for FFmpeg Length: ${frameFiles.map((file) => file.path).toList().length}');

      // Step 2: Check if video already exists and delete it if necessary
      final videoFile = File(videoFilePath);
      if (videoFile.existsSync()) {
        log('Video file already exists. Replacing the video...');
        await videoFile.delete(); // Delete the existing video file
      }

      //Step 3: Create video using FFmpeg
      final ffmpegCommand = [
        '-framerate', '3', // Adjust the framerate as needed
        '-i', '${framesDir.path}/frame_%03d.jpg',
        '-c:v', 'libx264',
        '-crf', '18', // Quality setting
        '-preset', 'slow',
        '-pix_fmt', 'yuv420p',
        '-b:v', '2M', // Video bitrate
        videoFilePath
      ].join(' ');


      log('Executing FFmpeg command: $ffmpegCommand');

      await FFmpegKit.execute(ffmpegCommand).then((session) async {
        final returnCode = await session.getReturnCode();
        final logs = await session.getAllLogsAsString();

        if (ReturnCode.isSuccess(returnCode)) {
          setState(() {
            _recordedVideoPath = videoFilePath;
          });

          // Navigate to the video preview screen
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => VideoPreviewScreen(videoPath: videoFilePath),
            ),
          );
        } else {
          log('FFmpeg failed with return code: $returnCode');
          log('FFmpeg logs: $logs');
        }
      });


    } catch (e) {
      print('Error during video generation: $e');
    } finally {
      setState(() {
        _isRecording = false;
      });
      _cleanupFrames(); // Delete frames after video creation
    }
  }


  void _cleanupFrames() async {
    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory('${tempDir.path}/pose_detection/frames');
    if (framesDir.existsSync()) {
      framesDir.deleteSync(recursive: true);
    }
  }


  @override
  Widget build(BuildContext context) {
    if (!_cameraController.value.isInitialized) {
      return Scaffold(
        appBar: AppBar(title: const Text("Pose Detection and Recording")),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final imageRotation = InputImageRotationValue.fromRawValue(cameras![0].sensorOrientation);
    return Scaffold(
      appBar: AppBar(title: const Text("Pose Detection and Recording")),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_cameraController),
          // Show countdown in the center during recording
          if (_remainingSeconds > 0)
            Center(
              child: Text(
                '$_remainingSeconds',
                style: const TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),

          // Progress indicator during processing
          if (_isRecording && _remainingSeconds == 0)
            const Center(
              child: CircularProgressIndicator(),
            ),
          CustomPaint(
            painter: PosePainter(
                _detectedPoses,
                _cameraController.value.previewSize!,
                imageRotation!
            ),
          ),

        ],
      )
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
    log('Canvas size: ${size.width}x${size.height}');
    log('Image size: ${absoluteImageSize.width}x${absoluteImageSize.height}');
    log('Rotation: $rotation');
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


double translateX(double x, InputImageRotation rotation, Size canvasSize, Size imageSize) {

  switch (rotation) {
    case InputImageRotation.rotation90deg:
      return x * (canvasSize.width) /imageSize.height;
    case InputImageRotation.rotation270deg:
      return canvasSize.width - x * canvasSize.width /  imageSize.height;
    default:
      return x * canvasSize.width / imageSize.width;
  }
}

double translateY(double y, InputImageRotation rotation, Size canvasSize, Size imageSize) {

  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y * canvasSize.height /  imageSize.width ;
    default:
      return y * canvasSize.height / imageSize.height;
  }
}





class VideoPreviewScreen extends StatefulWidget {
  final String videoPath;

  const VideoPreviewScreen({super.key, required this.videoPath});

  @override
  State<VideoPreviewScreen> createState() => _VideoPreviewScreenState();
}

class _VideoPreviewScreenState extends State<VideoPreviewScreen> {
  late VideoPlayerController _videoPlayerController;

  @override
  void initState() {
    super.initState();
    _videoPlayerController = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        setState(() {});
        _videoPlayerController.play();
      });
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Video Preview')),
      body: Center(
        child: _videoPlayerController.value.isInitialized
            ? AspectRatio(
          aspectRatio: _videoPlayerController.value.aspectRatio,
          child: VideoPlayer(_videoPlayerController),
        )
            : CircularProgressIndicator(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_videoPlayerController.value.isPlaying) {
            _videoPlayerController.pause();
          } else {
            _videoPlayerController.play();
          }
          setState(() {});
        },
        child: Icon(
          _videoPlayerController.value.isPlaying ? Icons.pause : Icons.play_arrow,
        ),
      ),
    );
  }
}

class SaveFrameArgs {
  final Uint8List frameBytes;
  final String framePath;

  SaveFrameArgs(this.frameBytes, this.framePath);
}

