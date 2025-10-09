const fs = require("fs");
const { exec } = require("child_process");
const { config } = require("process");

// 所有release地址
const all_release_url = "https://api.github.com/repos/amzxyz/rime_wanxiang/releases";
// 词库最新release地址
const last_release_url = "https://api.github.com/repos/amzxyz/rime_wanxiang/releases/tags/dict-nightly";

// 下载文件夹
const download_dir = "./tmp";
// 最新版本config的下载文件名
const origin_config_file_name = "config.zip";

const origin_dict_file_name = "dict.zip";

/**
 * 比较两个版本号
 * @param {string} v1 版本号1，如 "v13.0.9"
 * @param {string} v2 版本号2，如 "v13.0.6"
 * @returns {number} 1表示v1 > v2, -1表示v1 < v2, 0表示相等
 */
function compareVersions(v1, v2) {
  // 移除开头的'v'并分割版本号
  const parts1 = v1.replace(/^v/, "").split(".");
  const parts2 = v2.replace(/^v/, "").split(".");

  // 确保两个版本号有相同数量的部分
  const maxLength = Math.max(parts1.length, parts2.length);

  for (let i = 0; i < maxLength; i++) {
    // 将每部分转换为数字，如果不存在则视为0
    const num1 = parseInt(parts1[i] || "0", 10);
    const num2 = parseInt(parts2[i] || "0", 10);

    if (num1 > num2) return 1;
    if (num1 < num2) return -1;
  }

  return 0;
}

async function get_origin_last_version() {
  const res = await Promise.all([(await fetch(last_release_url)).json(), (await fetch(all_release_url)).json()]);

  const [last_dict, config_list] = res;

  const last_config = config_list
    .filter((item) => item.tag_name !== "dict-nightly")
    .sort((a, b) => {
      return compareVersions(a.tag_name, b.tag_name) > 0;
    })[0];

  return [last_dict, last_config];
}

function get_local_config_version() {
  return fs.readFileSync("version.txt", "utf8").trim();
}

function execute(cmd) {
  return new Promise((resolve, reject) => {
    exec(cmd, (err, stdout, stderr) => {
      if (err) {
        console.log(err)
        reject(err);
        return;
      }
      console.log(stdout, stderr)
      resolve(stdout);
    });
  });
}

async function download_file(url, filename) {
  if (!fs.existsSync(download_dir)) {
    fs.mkdirSync("tmp")
  }

  return await execute(`wget ${url} -O ${download_dir}/${filename}`);
}

async function unzip_file(filename, outdir) {
  return await execute(`7z x ${download_dir}/${filename} -o${outdir}`);

}

function update_config(last) {
  return new Promise(async (resolve, reject) => {
    const local_config_version = get_local_config_version();
    // 比较本地和远程版本
    const compareResult = compareVersions(last.tag_name, local_config_version);

    if (compareResult === 0 || compareResult === -1) {
      resolve();
      return;
    }
    // 获取文件url
    const download_url = last.assets.find((item) => item.name === "rime-wanxiang-base.zip").browser_download_url;
    await download_file(download_url, origin_config_file_name);
    await unzip_file(origin_config_file_name, `${download_dir}/config`);
    execute(`cp -rf ${download_dir}/config/* .`);
  });
}

async function update_dict(last) {
  const download_url = last.assets.find((item) => item.name === "base-dicts.zip").browser_download_url;
  await download_file(download_url, origin_dict_file_name);

  await unzip_file(origin_dict_file_name, `${download_dir}/dict`);
  execute(`cp -rf ${download_dir}/dict/base-dicts/* ./dicts/`);
}
async function main() {
  const [origin_dict_info, origin_config_info] = await get_origin_last_version();
  update_config(origin_config_info);
  update_dict(origin_dict_info);
}

main();
