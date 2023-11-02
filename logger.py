import logging
import time
import os


class Logger():
    def __init__(self, console_log = False, file_logging = False, file_URI = None, level = logging.DEBUG, override = False, log_name = "baselog"):
        self.log_name = log_name
        self.console_log = console_log
        self.file_logging = file_logging
        if file_logging:
            if file_URI is None:
                file_URI = "{}".format(self.log_name)+"_log_{}".format(time.asctime(time.localtime()))+".txt"
                
                    
            else:
                if os.path.exists(file_URI) and not override:
                    raise NameError("Log File already exists! Try setting override flag")
                else:
                    if os.path.exists(file_URI) and override:
                        os.remove(file_URI)
            file_URI = file_URI.replace(" ", "_").replace(":", "-")
            self.file_URI = file_URI
            logging.basicConfig(filename=file_URI, encoding='utf-8', level=level, format='%(asctime)s %(message)s')
            

    def warning(self, skk): #yellow
        
        if self.console_log:
            print("\033[93m {}\033[00m" .format("WARNING:"),"\033[93m {}\033[00m" .format(skk))
        if self.file_logging:
            logging.warning(skk)
       
    def error(self, skk): #red
        if self.console_log:   
            print("\033[91m {}\033[00m" .format("ERROR:"),"\033[91m {}\033[00m" .format(skk))
        if self.file_logging:
            logging.error(skk)
        
    def fail(self, skk): #red
        if self.console_log: 
            print("\033[91m {}\033[00m" .format("FATAL:"),"\033[91m {}\033[00m" .format(skk))
        if self.file_logging:
            logging.exception(skk)
    def passing(self, skk): #green
        if self.console_log: 
            print("\033[92m {}\033[00m" .format(skk))
        if self.file_logging:
            logging.info(skk)
    def passingblue(self, skk): #blue
        if self.console_log: 
            print("\033[96m {}\033[00m" .format(skk))
        if self.file_logging:
            logging.info(skk)
    def info(self, skk): #blue
        if self.console_log: 
            print("\033[94m {}\033[00m" .format("Info:"),"\033[94m {}\033[00m" .format(skk))
        if self.file_logging:
            logging.debug(skk)
    def chatReply(self,user, bot_name,skk):#blue
        if self.console_log: 
            print("\033[94m {}\033[00m" .format("{}".format(bot_name)+" to {}:".format(user)),"\033[94m {}\033[00m" .format(skk))
            
    def userReply(self,user,skk):#green
        if self.console_log: 
            print("\033[92m {}:\033[00m" .format(user),"\033[92m {}\033[00m" .format(skk))
            
            
            
