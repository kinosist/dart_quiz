// bin/quiz_server.dart

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:collection/collection.dart'; // Null Safety対応のため追加

/// クライアントを表すクラス
class Client {
  String name;
  WebSocket socket;
  int rank;

  Client(this.name, this.socket, {this.rank = 0});
}

/// クイズサーバーのクラス
class QuizServer {
  List<Client> clients = [];
  List<Map<String, dynamic>> questions = []; // クイズデータを格納するリスト
  int currentQuestionIndex = 0;
  bool acceptingAnswers = false;
  int rankCounter = 1;
  bool quizStarted = false; // クイズ開始フラグを追加
  bool isQuestionActive = false; // 質問がアクティブかどうかを示すフラグ

  HttpServer? _httpServer;

  /// サーバーの起動
  Future<void> startServer() async {
    try {
      // クイズデータの読み込み
      await loadQuestionsFromFile('questions.json');

      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        8080,
      );
      print('サーバーが ws://${_httpServer!.address.address}:8080 で起動しました');

      _httpServer!.listen((HttpRequest request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          try {
            WebSocket socket = await WebSocketTransformer.upgrade(request);
            handleWebSocket(socket);
          } catch (e) {
            print('WebSocket変換エラー: $e');
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.close();
          }
        } else {
          // 通常のHTTPリクエストに対するレスポンス
          request.response
            ..statusCode = HttpStatus.forbidden
            ..write('WebSocket connections only.')
            ..close();
        }
      });

      // シグナルハンドラーの設定
      ProcessSignal.sigint.watch().listen((signal) {
        print('SIGINTを受信しました。サーバーを停止します。');
        shutdown();
      });

      ProcessSignal.sigterm.watch().listen((signal) {
        print('SIGTERMを受信しました。サーバーを停止します。');
        shutdown();
      });
    } catch (e) {
      print('サーバー起動エラー: $e');
      exit(1);
    }
  }

  /// クイズデータをJSONファイルから読み込む
  Future<void> loadQuestionsFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        print('クイズデータファイルが見つかりません: $filePath');
        exit(1);
      }

      final contents = await file.readAsString();
      final List<dynamic> jsonData = jsonDecode(contents);

      // JSONデータをList<Map<String, dynamic>>に変換
      questions = jsonData.map<Map<String, dynamic>>((item) => Map<String, dynamic>.from(item)).toList();

      print('クイズデータが正常に読み込まれました。合計質問数: ${questions.length}');
    } catch (e) {
      print('クイズデータの読み込みエラー: $e');
      exit(1);
    }
  }

  /// WebSocket接続のハンドリング
  void handleWebSocket(WebSocket socket) {
    print('新しいクライアントが接続しました');

    // クライアントが接続時に名前を送信することを期待
    socket.listen((message) {
      try {
        var data = jsonDecode(message);
        print('受信メッセージ: $data');

        if (data['type'] == 'join') {
          var client = Client(data['name'], socket);
          clients.add(client);
          print('${client.name} が参加しました');

          // 歓迎メッセージを送信
          socket.add(jsonEncode({'type': 'welcome', 'message': 'ようこそ、${client.name}さん！'}));
        } else if (data['type'] == 'answer') {
          if (acceptingAnswers) {
            var client = clients.firstWhereOrNull((c) => c.socket == socket);
            if (client != null && client.rank == 0) {
              if (data['answer'] == questions[currentQuestionIndex]['answer']) {
                client.rank = rankCounter++;
                socket.add(jsonEncode({'type': 'rank', 'rank': client.rank}));
                print('${client.name} が正解しました。順位: ${client.rank}');
              } else {
                // 不正解の場合、「違います」と送信し、回答を受け付けない
                socket.add(jsonEncode({'type': 'feedback', 'message': '違います'}));
                print('${client.name} が不正解でした');
              }
            }
          }
        }
      } catch (e) {
        print('メッセージ処理エラー: $e');
        socket.add(jsonEncode({'type': 'error', 'message': 'メッセージ処理中にエラーが発生しました。'}));
      }
    }, onDone: () {
      var client = clients.firstWhereOrNull((c) => c.socket == socket);
      if (client != null) {
        clients.remove(client);
        print('${client.name} が切断しました');
        if (clients.isEmpty) {
          resetQuiz();
        }
      }
    }, onError: (error) {
      print('エラー: $error');
    });
  }

  /// クイズの開始
  void startQuiz() {
    if (quizStarted) {
      print('クイズはすでに開始されています。');
      return;
    }

    if (clients.isEmpty) {
      print('クライアントが接続されていません。クイズを開始できません。');
      return;
    }

    if (currentQuestionIndex >= questions.length) {
      print('クイズの質問が不足しています。');
      return;
    }

    quizStarted = true;
    rankCounter = 1;
    isQuestionActive = false; // 初期状態では質問がアクティブでない
    print('クイズを開始します');

    // 最初の質問を送信
    sendQuestion();
  }

  /// 次の質問を送信
  void sendNextQuestion() {
    if (!quizStarted) {
      print('クイズが開始されていません。');
      return;
    }

    if (isQuestionActive) {
      print('現在の質問がまだアクティブです。次の質問を送信できません。');
      return;
    }

    if (currentQuestionIndex < questions.length) {
      sendQuestion();
    } else {
      broadcast({'type': 'end', 'message': 'クイズ終了！'});
      print('すべてのクイズが終了しました。サーバーを停止します。');
      shutdown();
    }
  }

  /// クイズの出題
  void sendQuestion() {
    if (isQuestionActive) {
      print('既に質問が送信されています。新しい質問は送信できません。');
      return;
    }

    if (currentQuestionIndex >= questions.length) {
      print('全ての質問が終了しています。');
      return;
    }

    isQuestionActive = true;
    acceptingAnswers = true;
    var question = questions[currentQuestionIndex];
    var payload = {
      'type': 'question',
      'question': question['question'],
      'options': question['options']
    };
    broadcast(payload);
    print('質問を送信しました: ${question['question']}');

    // 回答受付時間を設定（例: 10秒）
    Timer(Duration(seconds: 10), () {
      acceptingAnswers = false;
      broadcast({'type': 'timeout', 'message': '時間切れです'});
      resetRanks();
      currentQuestionIndex++;
      isQuestionActive = false;
      print('次の質問の準備ができました。');
    });
  }

  /// クイズリセット
  void resetQuiz() {
    print('クライアントが全員切断されました。クイズをリセットします。');
    quizStarted = false;
    currentQuestionIndex = 0;
    acceptingAnswers = false;
    rankCounter = 1;
    isQuestionActive = false;
    // 他の必要なリセット処理をここに追加
  }

  /// クライアントにメッセージをブロードキャスト
  void broadcast(Map<String, dynamic> data) {
    var message = jsonEncode(data);
    for (var client in clients) {
      client.socket.add(message);
    }
  }

  /// 順位のリセット
  void resetRanks() {
    for (var client in clients) {
      client.rank = 0;
    }
    rankCounter = 1;
  }

  /// サーバーのシャットダウン
  Future<void> shutdown() async {
    print('サーバーをシャットダウンします...');
    for (var client in clients) {
      client.socket.close();
    }
    clients.clear();
    await _httpServer?.close(force: true);
    print('サーバーが停止しました。');
    exit(0);
  }
}

void main() async {
  var server = QuizServer();
  await server.startServer();

  print('Enterキーを押してクイズを開始します。');
  print('Enterキーを押して次の質問に進みます。');

  // 標準入力をリスン
  StreamSubscription<List<int>>? subscription;
  subscription = stdin.listen((data) {
    // Enterキー（改行）が押されたとき
    String input = String.fromCharCodes(data).trim();
    if (input.isEmpty) {
      if (!server.quizStarted) {
        server.startQuiz();
      } else {
        server.sendNextQuestion();
      }
    }
  });

  // サーバーが終了するまで待機
  await Future.delayed(Duration(days: 365));
}
