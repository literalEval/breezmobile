import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:breez/bloc/backup/backup_actions.dart';
import 'package:breez/bloc/backup/backup_bloc.dart';
import 'package:breez/bloc/backup/backup_model.dart';
import 'package:breez/bloc/user_profile/breez_user_model.dart';
import 'package:breez/bloc/user_profile/security_model.dart';
import 'package:breez/bloc/user_profile/user_actions.dart';
import 'package:breez/bloc/user_profile/user_profile_bloc.dart';
import 'package:breez/routes/shared/security_pin/backup_phrase/enter_backup_phrase_page.dart';
import 'package:breez/routes/shared/security_pin/backup_phrase/generate_backup_phrase_page.dart';
import 'package:breez/routes/shared/security_pin/restore_pin.dart';
import 'package:breez/routes/user/home/beta_warning_dialog.dart';
import 'package:breez/services/breezlib/breez_bridge.dart';
import 'package:breez/theme_data.dart' as theme;
import 'package:breez/widgets/backup_provider_selection_dialog.dart';
import 'package:breez/widgets/flushbar.dart';
import 'package:breez/widgets/loader.dart';
import 'package:breez/widgets/restore_dialog.dart';
import 'package:breez/widgets/route.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:breez/widgets/error_dialog.dart';
import 'package:hex/hex.dart';
import 'package:bip39/bip39.dart' as bip39;

class InitialWalkthroughPage extends StatefulWidget {
  final BreezUserModel _user;
  final UserProfileBloc _registrationBloc;
  final BackupBloc _backupBloc;
  final bool _isPos;

  InitialWalkthroughPage(this._user, this._registrationBloc, this._backupBloc, this._isPos);

  @override
  State createState() => new InitialWalkthroughPageState();
}

class InitialWalkthroughPageState extends State<InitialWalkthroughPage>
    with TickerProviderStateMixin {
  String _instructions;
  AnimationController _controller;
  Animation<int> _animation;

  StreamSubscription<bool> _restoreFinishedSubscription;
  StreamSubscription<List<SnapshotInfo>> _multipleRestoreSubscription;

  var _scaffoldKey = new GlobalKey<ScaffoldState>();
  bool _registered = false;  

  @override
  void initState() {
    super.initState();

    _instructions = widget._isPos ?
    "The simplest, fastest & safest way\nto earn bitcoin" :
    "The simplest, fastest & safest way\nto spend your bitcoins";    
    
    _multipleRestoreSubscription =
        widget._backupBloc.multipleRestoreStream.listen((options) async {
      if (options.length == 0) {
        popToWalkthrough(error: "Could not locate backup for this account");
        return;
      }


      SnapshotInfo toRestore;
      if (options.length == 1) {
        toRestore = options.first;
      } else {
        popToWalkthrough();        
        toRestore = await showDialog<SnapshotInfo>(
            context: context,
            builder: (_) =>
                new RestoreDialog(context, widget._backupBloc, options));
      }
      
      var restore = (SnapshotInfo snapshot, List<int> key) {
        widget._backupBloc.restoreRequestSink
              .add(RestoreRequest(snapshot, key));
        Navigator.push(
            context,
            createLoaderRoute(context,
                message: "Restoring data...", opacity: 0.8));
      };

      if (toRestore != null) {
        if (toRestore.encrypted) {
          if (toRestore.encryptionType == "Mnemonics") {
            restoreUsingPhrase((entrophy) async {
              await _createBackupPhrase(entrophy);
              var updateAction = UpdateBackupSettings(BackupSettings.start().copyWith(keyType: BackupKeyType.PHRASE));
              widget._backupBloc.backupActionsSink.add(updateAction);              
              updateAction.future.then((_) => restore(toRestore, HEX.decode(entrophy)));
            });
            return;
          }
          
          if (toRestore.encryptionType == "Pin") {
            restoreUsingPIN((pin) async {                            
              var updateAction = UpdateBackupSettings(BackupSettings.start().copyWith(keyType: BackupKeyType.NONE));
              var key = sha256.convert(utf8.encode(pin));
              widget._backupBloc.backupActionsSink.add(updateAction); 
              updateAction.future.then((_) => restore(toRestore, key.bytes));
            });
            return;            
          }
        }

        restore(toRestore, null);

      }
    }, onError: (error) {
      popToWalkthrough(
          error: error.runtimeType != SignInFailedException
              ? error.toString()
              : null);
      if (error.runtimeType == SignInFailedException) {
        _handleSignInException(error as SignInFailedException);
      }
    });

    _restoreFinishedSubscription =
        widget._backupBloc.restoreFinishedStream.listen((restored) {      
      if (restored) {
        popToWalkthrough();
        _proceedToRegister();
      }
    }, onError: (error) {
      Navigator.of(context).pop();
      if (error.runtimeType != SignInFailedException) {
        showFlushbar(context, duration: new Duration(seconds: 3),
          message: error.toString());
      }
      else {
        _handleSignInException(error as SignInFailedException);
      }      
    });

    _controller = new AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2720))
      ..forward(from: 0.0);
    _animation = new IntTween(begin: 0, end: 67).animate(_controller);
    if (_controller.isCompleted) {
      _controller.stop();
      _controller.dispose();
    }
  }

  Future _handleSignInException(SignInFailedException e) async {
    if (e.provider == BackupSettings.icloudBackupProvider) {
      await promptError(context, "Sign in to iCloud", Text("Sign in to your iCloud account. On the Home screen, launch Settings, tap iCloud, and enter your Apple ID. Turn iCloud Drive on. If you don't have an iCloud account, tap Create a new Apple ID.", style: theme.alertStyle));
    }
  }

  Future<String> restoreUsingPhrase(Function(String key) onKeySubmitted) {
    return Navigator.of(context).push(new FadeInRoute(
      builder: (BuildContext context) {
        return EnterBackupPhrasePage(onPhraseSubmitted: onKeySubmitted);
      },
    ));
  }

  Future _createBackupPhrase(String entrophy) async {
    var saveBackupKeyAction = SaveBackupKey(entrophy);
    widget._backupBloc.backupActionsSink.add(saveBackupKeyAction);
    return saveBackupKeyAction.future.catchError((err) {
      promptError(
          context,
          "Internal Error",
          Text(
            err.toString(),
            style: theme.alertStyle,
          ));
    });
  }

  Future<String> restoreUsingPIN(Function(String key) onKeySubmitted) {
    return Navigator.of(context).push(new FadeInRoute(
      builder: (BuildContext context) {
        return RestorePinCode(onPinCodeSubmitted: onKeySubmitted);
      },
    ));
  }

  void popToWalkthrough({String error}) {
    Navigator.popUntil(context, (route) {
      return route.settings.name == "/intro";
    });
    if (error != null) {
      _scaffoldKey.currentState.showSnackBar(new SnackBar(
          duration: new Duration(seconds: 3),
          content: new Text(error.toString())));
    }
  }

  @override
  void dispose() {
    _multipleRestoreSubscription.cancel();
    _restoreFinishedSubscription.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _proceedToRegister() {
    widget._registrationBloc.registerSink.add(null);
    _registered = true;
    Navigator.of(context).pop();
  }

  Future<bool> _onWillPop() async {
    if (!_registered) {
      exit(0);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return new Scaffold(
      key: _scaffoldKey,
      body: WillPopScope(
        onWillPop: _onWillPop,
        child: Padding(
            padding: new EdgeInsets.only(top: 24.0),
            child: new Stack(children: <Widget>[
              new Column(
                children: <Widget>[
                  new Expanded(flex: 244, child: new Container()),
                  new Expanded(
                      flex: 372,
                      child: new Image.asset(
                        'src/images/waves-middle.png',
                        fit: BoxFit.cover,
                        width: double.infinity,
                      )),
                ],
              ),
              new Column(
                children: <Widget>[
                  new Expanded(flex: 60, child: new Container()),
                  new Expanded(
                    flex: 151,
                    child: new AnimatedBuilder(
                      animation: _animation,
                      builder: (BuildContext context, Widget child) {
                        String frame =
                            _animation.value.toString().padLeft(2, '0');
                        return new Image.asset(
                          'src/animations/welcome/frame_${frame}_delay-0.04s.png',
                          gaplessPlayback: true,
                          fit: BoxFit.cover,
                        );
                      },
                    ),
                  ),
                  new Expanded(flex: 190, child: new Container()),
                  new Expanded(
                    flex: 48,
                    child: Padding(
                      padding: EdgeInsets.only(left: 24, right: 24),
                      child: AutoSizeText(
                        _instructions,
                        textAlign: TextAlign.center,
                        style: theme.welcomeTextStyle,
                      ),
                    ),
                  ),
                  new Expanded(flex: 79, child: new Container()),
                  Container(
                    height: 48.0,
                    width: 168.0,
                    child: RaisedButton(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text("LET'S BREEZ!", style: theme.buttonStyle),
                      color: theme.whiteColor,
                      elevation: 0.0,
                      shape: const StadiumBorder(),
                      onPressed: () {
                        showDialog(
                            context: context,
                            barrierDismissible: false,
                            builder: (BuildContext context) {
                              return BetaWarningDialog();
                            }).then((approved) {
                          if (approved) {
                            UpdateSecurityModel updateSecurityModelAction = UpdateSecurityModel(SecurityModel.initial());
                            widget._registrationBloc.userActionsSink.add(updateSecurityModelAction);
                            updateSecurityModelAction.future.then((_) {
                              _proceedToRegister();
                            }).catchError((err) {
                              promptError(context, "Internal Error", Text(err.toString(), style: theme.alertStyle,));
                            });
                          }
                        });
                      },
                    ),
                  ),
                  new Expanded(
                    flex: 40,
                    child: new Padding(
                        padding: EdgeInsets.only(top: 10.0),
                        child: new GestureDetector(
                            onTap: () {
                              widget._backupBloc.backupSettingsStream.first.then((settings) async {
                                var backupProvider = settings.backupProvider;
                                if (backupProvider == null || BackupSettings.availableBackupProviders().length > 1) {
                                  backupProvider = await showDialog(context: context, builder: (_) => 
                                    BackupProviderSelectionDialog(backupBloc: widget._backupBloc, restore: true));
                                }                           
                                if (backupProvider != null) {
                                  // Restore then start lightninglib
                                  Navigator.push(
                                    context, createLoaderRoute(context));
                                    widget._backupBloc.restoreRequestSink.add(null);
                                  }
                              });                              
                            },
                            child: new Text(
                              "Restore from backup",
                              style: theme.restoreLinkStyle,
                            ))),
                  ),
                ],
              )
            ])),
      ),
    );
  }
}
