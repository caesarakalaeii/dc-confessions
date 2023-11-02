# ConfessionBot

ConfessionBot is a simple bot built using Python for Discord. It accepts user confessions via Direct Message (DM) and anonymously posts them on a specified channel.

## Features

- UnpackMessage function that translates a message object into usable content.
- Message handler function that sends received messages to the specific channel on Discord.
- Confidential handling of user information.

## Getting Started

Clone the repository using `git clone` command, or download the zip file from Github and extract the contents.

### Prerequisites

ConfessionBot requires the following modules:

- Python 3.5 or newer
- discord.py

To install the above modules, use pip:

- Python: `https://www.python.org/downloads/`
- discord.py: `pip install discord.py`

## Usage

1. Replace the BOT_TOKEN and CHANNEL_ID in the `ConfessionBot class` with your own bot token and preferred channel ID.
2. Run the bot using `python bot.py`.
3. Now, whatever DM the bot receives, it will be posted anonymously on your preferred channel.

## Contribute

If you want to contribute, feel free to open an issue or submit a pull request!

## Troubleshooting

If you encounter any issues, please open an issue on GitHub!

## License

ConfessionBot is free to use, modify, and distribute following the terms of the license, providing changes are properly documented.
