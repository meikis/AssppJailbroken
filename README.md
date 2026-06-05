# AssppWeb For iOS

A tool for decrypting freshly downloaded ipa from App Store. And even modified to run on iPhone Simulator. 

## Usage

### Device Preperation

Buy a iPhone (that can be jailbroken), then use (no matter what you can to jailbreak -- but tested only on Dopamine2)

Then login to App Store, and download a free app for credentials.

### Install package.

with theos installed

```bash
make install DEVICE_HOST=root@<device-host>
```

The root install target also accepts Theos device variables:

```bash
THEOS=/Users/libr/theos THEOS_DEVICE_IP=<device-host> make install
```

### Use

visit http://{ip}:8080/ and there's one webui to use.


>[!WARNING]
>Do not expose this service to public without authing.
>Do not use any public instances since i **removed** the zerotrust code, it's really dangerous!


## Known Issues

Apple has been doing rate limit over requests without full apple environment.

When met these issues, please just wait and do the request later.

## Creds

[Lakr233/AssppWeb](https://github.com/Lakr233/AssppWeb)

[lbr77/unfair](https://github.com/lbr77/unfair)

[lbr77/unfaird](https://github.com/lbr77/unfaird)
