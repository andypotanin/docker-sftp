/**
 * Container Cleanup Utility for Docker SFTP Gateway
 * 
 * This script removes all container records from Firebase storage:
 * - Connects to the container collection
 * - Logs the number of containers found
 * - Removes all container records
 * - Provides error handling and reporting
 * 
 * Usage:
 * node bin/flush-containers.js
 * 
 * Note: This is a maintenance utility that should be used with caution
 * as it permanently removes container data from Firebase.
 */

var utility = require( '../lib/utility' );
var _ = require( 'lodash' );

var _containerCollection = utility.getCollection( 'container', '', function ( error, data ) {

    console.log('Get [%s] container item.', _.size(data) );

    _containerCollection.remove(function ( error ) {

        if( !error ) {
            console.log( 'Done flushing.' );
        } else {
            console.error( 'Error flushing' );
            console.log(require('util').inspect(error, {showHidden: false, depth: 2, colors: true}));
        }

        process.exit();

    });

});