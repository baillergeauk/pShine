pShine
======

What is pShine
--------------
pShine is a bash script using [pcocc](https://github.com/cea-hpc/pcocc) and [shine](https://github.com/cea-hpc/shine) to deploy a virtual cluster with a Lustre filesystem

It is basically creating the templates/cloud-configs for pcocc, launching the cluster and installing the Lustre FS with shine


Prerequisites
-------------
Images used within the templates must have been prepared beforehand

1. Lustre and shine must be installed
2. Both images must allow root ssh public key authentication from the server one
  * if you're using the same image for servers and clients, simply put the root public key into root authorized_keys file
  * if they are different, the root public key of the server image should also be put into the root authorized_keys of client image
3. Both images must have the line *StrictHostKeyChecking=no* in their ssh config file
 
Usage
-----

Create and launch a pcocc Cluster with a Lustre FS based on a configuration file:

    # ./pShine create MODEL_FILE


Start a previously created one with desired pcocc options:

    # ./pShine start -c CORE_NUMBER -p PARTITION -f FSNAME


Delete an entire pcocc Cluster with Lustre FS:

    # ./pShine delete FSNAME


Additional informations
-----------------------

* /!\ pShine creates the entire cluster based on the filesystem's name, creating another with the same name will totally overwrite the previous one /!\

* /!\ Be careful when using ```pShine delete```, files will be listed so make sure you agree with the list before accepting /!\

* If you plan to reuse a filesystem with ```pShine start```, make sure you unmount all the clients before shutting down the cluster.
If not doing so, the MDS will enter recovery at next start and it can take atleast 5mins to complete.

* Before using pShine, make sure you already have a generated rsa key at *~/.ssh/id_rsa.pub* as it will be used for the cloud-config
