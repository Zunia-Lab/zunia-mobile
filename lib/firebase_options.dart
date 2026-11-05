// Firebase project zunia-72ab8, in the FlutterFire layout. Built from
// android/app/google-services.json and ios/Runner/GoogleService-Info.plist,
// which come from the Firebase console; change those, then this, together.
// Client configuration, embedded in every build: not a secret.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Zunia has no Firebase web app.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'Zunia has no Firebase app for $defaultTargetPlatform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAxloIvBc41pRBEAtNR4_s6EOXrQcBY96Y',
    appId: '1:300954721664:android:f06619579c37c655767565',
    messagingSenderId: '300954721664',
    projectId: 'zunia-72ab8',
    storageBucket: 'zunia-72ab8.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyCiTWmCnP2wY2zyT46aNx9L1xr2E_X-KFE',
    appId: '1:300954721664:ios:8cf4c17e998f3b74767565',
    messagingSenderId: '300954721664',
    projectId: 'zunia-72ab8',
    storageBucket: 'zunia-72ab8.firebasestorage.app',
    iosBundleId: 'com.zuniawallet.zuniaMobile',
  );
}
