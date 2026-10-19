import 'package:http/http.dart' as http;

import 'progress_client.dart';

const reportsProgress = false;

http.Client createProgressClient(UploadProgress? Function() progress) =>
    http.Client();
