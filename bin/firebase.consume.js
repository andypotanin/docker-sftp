/**
 * Firebase Consumer for Docker SFTP Gateway
 * 
 * This script monitors Firebase for container changes and updates SSH access:
 * - Watches deployment collection for changes
 * - Queues changes for processing
 * - Updates SSH keys based on deployment changes
 * - Runs periodic checks every 30 seconds
 * 
 * Environment Variables:
 * - FIREBASE_PROJECT_ID: Firebase project ID
 * - FIREBASE_PRIVATE_KEY_ID: Private key ID
 * - FIREBASE_PRIVATE_KEY: Private key (with escaped newlines)
 * - FIREBASE_CLIENT_EMAIL: Service account email
 * - FIREBASE_CLIENT_ID: Client ID
 * 
 * Usage:
 * node opt/firebase.consume.js
 * 
 * Note: This script is part of the container lifecycle management system
 * and works in conjunction with controller.keys.js
 */

//var newrelic = require('newrelic')
var admin = require('firebase-admin/lib/index');
var _ = require( 'lodash' );

exports.changeQueue = [];

var firebaseConfig = {
    'type': 'service_account',
    'project_id': process.env.FIREBASE_PROJECT_ID,
    'private_key_id': process.env.FIREBASE_PRIVATE_KEY_ID,
    'private_key': process.env.FIREBASE_PRIVATE_KEY.split('\\n' ).join( '\n' ),
    'client_email': process.env.FIREBASE_CLIENT_EMAIL,
    'client_id': process.env.FIREBASE_CLIENT_ID,
    'auth_uri': 'https://accounts.google.com/o/oauth2/auth',
    'token_uri': 'https://accounts.google.com/o/oauth2/token',
    'auth_provider_x509_cert_url': 'https://www.googleapis.com/oauth2/v1/certs',
    'client_x509_cert_url': process.env.FIREBASE_CLIENT_CERT_URL
};

admin.initializeApp({
    credential: admin.credential.cert(firebaseConfig),
    databaseURL: 'https://rabbit-v2.firebaseio.com'
});

var deploymentCollection = admin.database().ref('deployment');

// once initial data is loaded.
deploymentCollection.once('value', haveInitialData );

function haveInitialData( snapshot ) {
    console.log('haveInitialData - Have initial data with [%d] documents.', _.size( snapshot.val() ) );

    //console.log(require('util').inspect(snapshot.toJSON(), {showHidden: false, depth: 2, colors: true}));
    //process.exit();
    require('../lib/utility').updateKeys({
        keysPath: '/etc/ssh/authorized_keys.d',
        passwordFile: '/etc/passwd',
        passwordTemplate: 'alpine.passwords'
    }, function (err) {
        if (err) {
            console.error('Error updating keys:', err);
        }
    });
}

// do not use child_added or it'll iterate over every single one
deploymentCollection.on('child_changed', addtToChangeQueue );

function addtToChangeQueue( data ) {
    console.log('addtToChangeQueue', _.size( data.val( ) ) );

    exports.changeQueue.push( data );
}

/**
 * Ran on initial load as well.
 *
 * @param data
 */

/**
 * If have items in changeQueue, run once first payload from first item.
 */
function maybeUpdateKeys() {
    console.log( 'maybeUpdateKeys - ', _.size( exports.changeQueue ) );


    if( _.size( exports.changeQueue ) > 0 ) {
        console.log( 'maybeUpdateKeys - have keys' );
        require('../lib/utility').updateKeys({
            keysPath: '/etc/ssh/authorized_keys.d',
            passwordFile: '/etc/passwd',
            passwordTemplate: 'alpine.passwords'
        }, function (err) {
            if (err) {
                console.error('Error updating keys:', err);
            }
        });
        exports.changeQueue = [];

    } else {
        console.log( 'maybeUpdateKeys - skip' );
    }

}

// Check every 30s
setInterval(maybeUpdateKeys,30000);

// Removed unused function
