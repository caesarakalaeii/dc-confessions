import discord
from logger import Logger
import asyncio
from config import *

 

class ConfessionBot:
    
    def __init__(self, bot_token, channel_id) -> None:
        self.channel_id = channel_id
        self.logger  = Logger(True, True)
        self.__bot_token = bot_token
        pass
    
    
    async def message_handler(self, message : discord.Message):
        
        content, files = await self.unpackMessage(message)
        
        content = f'Confession:\n' + content
        
        channel = self.bot.get_channel(self.channel_id)
        if len(content) > 2000:
            await channel.send(content = content[:2000])
            content = content [2000:]
        await channel.send(content = content, files= files)
        
        
    async def unpackMessage(self, message_object : discord.Message):
        files = []
        attachments = message_object.attachments
        
        for a in attachments:
            files.append(await a.to_file())
        return message_object.content, files
    
    
    def run_bot(self):
        intents = discord.Intents.default()
        intents.messages = True
        intents.guilds = True
        bot = discord.Client(intents=intents) 
        
        self.bot = bot
        
        @bot.event
        async def on_ready():
            self.logger.passing(f"Logged in as {bot.user.name}")
            

        @bot.event
        async def on_message(message : discord.Message):
            if isinstance(message.channel, discord.DMChannel) and message.author != bot.user:
                await self.messageHandler(message)
        bot.run(self.__bot_token)
    

    
if __name__ == "__main__":
    
    bot = ConfessionBot()
    bot.run_bot(BOT_TOKEN, CHANNEL_ID)
         
